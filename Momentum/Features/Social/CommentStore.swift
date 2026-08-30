import Foundation
import Observation

/// The user's own comments (docs/SOCIAL-LAYER.md). Local + persisted (UserDefaults JSON), pushed to
/// Supabase behind the send. Keyed by post id. Light moderation runs on add.
@MainActor
@Observable
final class CommentStore {
    private static let key = "com.momentum.social.comments"
    private static let pendingKey = "com.momentum.social.commentsPending"
    private let defaults: UserDefaults
    private(set) var byPost: [String: [Comment]]

    /// Comment ids the network never saw — written offline, or written as a GUEST, where there is
    /// no session to write under. Persisted: a comment is text the athlete typed, and the weeks
    /// between a guest writing one and signing up must not quietly turn it into a note to self.
    /// `flushPending` retries them on the next feed refresh.
    ///
    /// A comment the server actively REFUSED never enters the set — a seeded community post has
    /// no server row to hang a comment on, so its push can only fail. Reachability, not failure,
    /// is the test (the same rule `ReactionStore` uses).
    private(set) var pending: Set<UUID>

    /// Wired once in `MomentumApp`; nil in tests/previews → the store stays purely local.
    @ObservationIgnored var backend: (any SocialBackending)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SocialDebug.resetIfRequested(defaults, keys: [Self.key, Self.pendingKey, Self.draftsKey])
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: [Comment]].self, from: data) {
            byPost = decoded
        } else {
            byPost = [:]
        }
        pending = Set((defaults.stringArray(forKey: Self.pendingKey) ?? []).compactMap(UUID.init(uuidString:)))
        drafts = (defaults.dictionary(forKey: Self.draftsKey) as? [String: String] ?? [:])
            .filter { !CommunityPostID.isEphemeral($0.key) }
        // Purge threads hung off a pull-to-refresh post (see `CommunityPostID`): those ids are
        // re-minted from zero next launch, so a kept comment can surface under a post the athlete
        // never opened. Done on LOAD so an install that already carries one is clean immediately.
        let poisoned = byPost.keys.filter { CommunityPostID.isEphemeral($0) }
        if !poisoned.isEmpty {
            let orphaned = Set(poisoned.flatMap { byPost[$0] ?? [] }.map(\.id))
            for key in poisoned { byPost.removeValue(forKey: key) }
            pending.subtract(orphaned)
            persist()
        }
    }

    func comments(for postID: UUID) -> [Comment] { byPost[postID.uuidString] ?? [] }

    // MARK: Unsent drafts

    /// What the athlete had typed but not sent, per post. The composer is `@State` on a sheet, so
    /// swiping the sheet away — or a phone call arriving mid-sentence — used to throw the text
    /// away with no way back (2026-08-29). Reopening the thread now restores it.
    ///
    /// Held in memory and written on the way out (`PostCommentsView.onDisappear`) rather than on
    /// every keystroke: the store outlives the sheet, so the common loss is dismissal, not a
    /// process kill. Ephemeral posts are excluded from the write like everything else.
    private static let draftsKey = "com.momentum.social.commentDrafts"
    private(set) var drafts: [String: String] = [:]

    func draft(for postID: UUID) -> String { drafts[postID.uuidString] ?? "" }

    func setDraft(_ text: String, for postID: UUID) {
        let key = postID.uuidString
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard drafts.removeValue(forKey: key) != nil else { return }
        } else {
            guard drafts[key] != text else { return }
            drafts[key] = text
        }
        persistDrafts()
    }

    private func persistDrafts() {
        let durable = drafts.filter { !CommunityPostID.isEphemeral($0.key) }
        defaults.set(durable, forKey: Self.draftsKey)
    }

    /// Add the user's comment after light moderation. Returns the added comment, or nil if it was
    /// empty after cleaning (nothing to post).
    @discardableResult
    func add(_ raw: String, to postID: UUID, authorName: String, authorHandle: String?,
             now: Date = Date()) -> Comment? {
        guard let text = CommentModeration.clean(raw) else { return nil }
        let comment = Comment(id: UUID(), postID: postID, authorName: authorName,
                              authorHandle: authorHandle, isCommunity: false, text: text, date: now)
        byPost[postID.uuidString, default: []].append(comment)
        // A pulse post has no server row and no id worth keeping — the comment is real for as
        // long as the post is on screen and goes no further (see `CommunityPostID`).
        guard !CommunityPostID.isEphemeral(postID) else { persist(); return comment }
        // Pending FIRST, then push. Recording the intent only after the network answers would
        // lose the athlete's text if the app is killed during the call.
        pending.insert(comment.id)
        persist()
        // The client-generated id makes the server upsert idempotent, so a retry can never
        // duplicate the comment.
        Task { await push(comment) }
        return comment
    }

    func delete(_ comment: Comment) {
        byPost[comment.postID.uuidString]?.removeAll { $0.id == comment.id }
        pending.remove(comment.id)
        persist()
        let backend = backend
        Task { await backend?.deleteComment(id: comment.id) }
    }

    /// Push one comment. Confirmed → done. Refused by a REACHABLE backend → nothing to retry.
    /// Unreachable → the entry stays where `add`/`flushPending` put it.
    private func push(_ comment: Comment) async {
        guard let backend else { pending.remove(comment.id); persist(); return }
        if await backend.pushComment(comment) {
            pending.remove(comment.id)
            persist()
        } else if await backend.isAvailable {
            pending.remove(comment.id)
            persist()
        }
    }

    /// Retry every comment the network never saw. Called on feed refresh — which is both a proof
    /// the backend is reachable and the first thing that happens after a guest signs in.
    func flushPending() {
        guard backend != nil, !pending.isEmpty else { return }
        let all = byPost.values.flatMap { $0 }
        for id in pending {
            guard let comment = all.first(where: { $0.id == id }) else {
                pending.remove(id); persist(); continue    // deleted underneath us
            }
            Task { await push(comment) }
        }
    }

    /// Pull the thread for one post and merge it in (called when a post's comments open).
    func pullRemote(for postID: UUID) {
        flushPending()   // opening a thread is also a chance to deliver what never left
        let backend = backend
        Task {
            guard let remote = await backend?.pullComments(postID: postID) else { return }
            merge(remote: remote, for: postID)
        }
    }

    /// Merge remote comments for a post — dedup by id (own pushed comments come back too),
    /// oldest first, persisted so the thread reads offline next time.
    func merge(remote: [Comment], for postID: UUID) {
        guard !remote.isEmpty else { return }
        let key = postID.uuidString
        var list = byPost[key] ?? []
        let existing = Set(list.map(\.id))
        let fresh = remote.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        list = (list + fresh).sorted { $0.date < $1.date }
        byPost[key] = list
        persist()
    }

    /// Threads on ephemeral posts never reach disk — they stay in memory so the open thread reads
    /// right, and the next launch starts without them.
    private func persist() {
        let durable = byPost.filter { !CommunityPostID.isEphemeral($0.key) }
        if let data = try? JSONEncoder().encode(durable) { defaults.set(data, forKey: Self.key) }
        defaults.set(pending.map(\.uuidString).sorted(), forKey: Self.pendingKey)
    }
}
