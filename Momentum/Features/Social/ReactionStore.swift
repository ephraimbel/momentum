import Foundation
import Observation

/// The athlete's "respect" reactions (docs/SOCIAL-LAYER.md, Slice 4). Local + persisted; the
/// reaction pushes to Supabase behind the tap. Keyed by post id. The displayed count is the post's
/// seeded baseline plus the viewer's own reaction — the viewer's tap is always real, in the same
/// frame, whether or not the network agrees yet.
@MainActor
@Observable
final class ReactionStore {
    private static let key = "com.momentum.social.reactions"
    private static let pendingKey = "com.momentum.social.reactionsPending"
    private let defaults: UserDefaults
    private(set) var reacted: Set<String>

    /// Post ids whose server write could not even be attempted — a tap made offline, or made as a
    /// GUEST, where there is no session to write under. Persisted, because the weeks between a
    /// guest's tap and their sign-up must not turn a real reaction into one that existed only on
    /// this device (the "silently doing nothing" failure, 2026-08-29). `flushPending` retries them
    /// the next time the feed refreshes.
    ///
    /// A write the server actively REFUSED never enters the set: a seeded community post has no
    /// server row, so its push can only ever fail, and retrying it forever would cost a futile
    /// round trip per refresh for every post on the wall. Reachability, not failure, is the test.
    private(set) var pending: Set<String>

    /// Wired once in `MomentumApp`; nil in tests/previews → the store stays purely local.
    @ObservationIgnored var backend: (any SocialBackending)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SocialDebug.resetIfRequested(defaults, keys: [Self.key, Self.pendingKey])
        let stored = Set(defaults.stringArray(forKey: Self.key) ?? [])
        let storedPending = Set(defaults.stringArray(forKey: Self.pendingKey) ?? [])
        // Drop anything keyed to a pull-to-refresh post (see `CommunityPostID`). Purging on LOAD
        // rather than only on the next write means an install that already carries a poisoned key
        // is clean from its first launch on this build, instead of showing a filled heart on a
        // stranger's post until something else happens to save.
        reacted = stored.filter { !CommunityPostID.isEphemeral($0) }
        pending = storedPending.filter { !CommunityPostID.isEphemeral($0) }
        if reacted != stored || pending != storedPending { persist() }
    }

    func hasReacted(_ id: UUID) -> Bool { reacted.contains(id.uuidString) }

    func toggle(_ id: UUID) {
        let key = id.uuidString
        if reacted.contains(key) { reacted.remove(key) } else { reacted.insert(key) }
        // A pulse post has no server row and no id worth keeping — the tap is real for as long as
        // the post is on screen and goes no further.
        guard !CommunityPostID.isEphemeral(key) else { persist(); return }
        // Pending FIRST, then push (the `FollowStore` order). Recording the intent only after the
        // network answers would lose it if the app is killed during the call — which on a slow or
        // dead connection is exactly the window that lasts longest.
        pending.insert(key)
        persist()
        let isReacted = reacted.contains(key)
        Task { await push(id, reacted: isReacted) }
    }

    /// Push one intent. Confirmed → clear it. Refused by a REACHABLE backend → also clear it (the
    /// post has no server row; see `pending`). Unreachable → leave it for `flushPending`.
    private func push(_ id: UUID, reacted isReacted: Bool) async {
        let key = id.uuidString
        guard let backend else { pending.remove(key); persist(); return }   // local-only build
        if await backend.setReaction(postID: id, reacted: isReacted) {
            pending.remove(key)
            persist()
        } else if await backend.isAvailable {
            pending.remove(key)     // a live session refused it — nothing to retry
            persist()
        }
        // Unreachable: the entry stays exactly where `toggle` put it.
    }

    /// Retry every reaction the network never saw. Called when the feed refreshes — which is both
    /// a proof the backend is reachable and the first thing that happens after a guest signs in
    /// and opens Community.
    func flushPending() {
        guard backend != nil, !pending.isEmpty else { return }
        for key in pending {
            guard let id = UUID(uuidString: key) else { pending.remove(key); persist(); continue }
            Task { await push(id, reacted: reacted.contains(key)) }
        }
    }

    /// Total respects to show: the post's baseline + 1 if the viewer reacted.
    func count(for item: FeedItem) -> Int {
        item.baseReactions + (hasReacted(item.id) ? 1 : 0)
    }

    /// Merge the server's record of the viewer's reactions for a fetched page (remote rows carry
    /// `viewer_reacted`). Additive only — a local tap the server hasn't seen yet must survive, and
    /// an un-react still waiting to push must not be resurrected by the page that carries it.
    func merge(viewerReacted remote: Set<String>) {
        let adopt = remote.subtracting(reacted).subtracting(pending)
        guard !adopt.isEmpty else { return }
        reacted.formUnion(adopt)
        persist()
    }

    /// Ephemeral keys never reach disk — the in-memory sets keep them so the current session's
    /// taps look and count right, and the next launch starts without them.
    private func persist() {
        defaults.set(reacted.filter { !CommunityPostID.isEphemeral($0) }.sorted(), forKey: Self.key)
        defaults.set(pending.filter { !CommunityPostID.isEphemeral($0) }.sorted(), forKey: Self.pendingKey)
    }
}
