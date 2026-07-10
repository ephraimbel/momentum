import Foundation
import Observation

/// The user's own comments (docs/SOCIAL-LAYER.md). Local + persisted (UserDefaults JSON); syncs to
/// Supabase with the rest of social later. Keyed by post id. Light moderation runs on add.
@MainActor
@Observable
final class CommentStore {
    private static let key = "com.momentum.social.comments"
    private let defaults: UserDefaults
    private(set) var byPost: [String: [Comment]]

    /// Wired once in `MomentumApp`; nil in tests/previews → the store stays purely local.
    @ObservationIgnored var backend: (any SocialBackending)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SocialDebug.resetIfRequested(defaults, keys: [Self.key])
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: [Comment]].self, from: data) {
            byPost = decoded
        } else {
            byPost = [:]
        }
    }

    func comments(for postID: UUID) -> [Comment] { byPost[postID.uuidString] ?? [] }

    /// Add the user's comment after light moderation. Returns the added comment, or nil if it was
    /// empty after cleaning (nothing to post).
    @discardableResult
    func add(_ raw: String, to postID: UUID, authorName: String, authorHandle: String?,
             now: Date = Date()) -> Comment? {
        guard let text = CommentModeration.clean(raw) else { return nil }
        let comment = Comment(id: UUID(), postID: postID, authorName: authorName,
                              authorHandle: authorHandle, isCommunity: false, text: text, date: now)
        byPost[postID.uuidString, default: []].append(comment)
        persist()
        // Fire-and-forget; the client-generated id makes the server upsert idempotent. Comments
        // on seeded posts have no server post row and no-op under the FK/RLS.
        let backend = backend
        Task { await backend?.pushComment(comment) }
        return comment
    }

    func delete(_ comment: Comment) {
        byPost[comment.postID.uuidString]?.removeAll { $0.id == comment.id }
        persist()
        let backend = backend
        Task { await backend?.deleteComment(id: comment.id) }
    }

    /// Pull the thread for one post and merge it in (called when a post's comments open).
    func pullRemote(for postID: UUID) {
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

    private func persist() {
        if let data = try? JSONEncoder().encode(byPost) { defaults.set(data, forKey: Self.key) }
    }
}
