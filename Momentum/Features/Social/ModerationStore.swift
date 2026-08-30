import Foundation
import Observation

/// Local moderation — block athletes and report/hide posts (docs/SOCIAL-LAYER.md, Slice 5). Required
/// before any real UGC ships (App Store UGC rules). Persisted locally; syncs to Supabase (server-side
/// enforcement + report queue) with the rest of social. Blocking hides an athlete everywhere
/// (feed, globe, following); reporting hides that single post immediately.
@MainActor
@Observable
final class ModerationStore {
    private static let blockedKey = "com.momentum.social.blocked"
    private static let reportedKey = "com.momentum.social.reported"
    private let defaults: UserDefaults

    private(set) var blockedHandles: Set<String>
    private(set) var reportedPosts: Set<String>

    /// Wired once in `MomentumApp`; nil in tests/previews → the store stays purely local.
    @ObservationIgnored var backend: (any SocialBackending)?

    /// Wired once in `MomentumApp`. Blocking someone you follow must also unfollow them —
    /// otherwise their face keeps its place in the Following ring row and the follow list, their
    /// handle keeps counting toward "Following", and the Friends scope keeps a slot for an
    /// athlete whose every post is hidden. Only the athlete-profile menu used to do this by hand,
    /// so a block from the pager or a comment thread left all of that behind (found 2026-08-29).
    /// Doing it in the store makes it true at EVERY block site, present and future.
    @ObservationIgnored weak var follows: FollowStore?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SocialDebug.resetIfRequested(defaults, keys: [Self.blockedKey, Self.reportedKey])
        blockedHandles = Set(defaults.stringArray(forKey: Self.blockedKey) ?? [])
        reportedPosts = Set(defaults.stringArray(forKey: Self.reportedKey) ?? [])
    }

    func isBlocked(_ handle: String) -> Bool { blockedHandles.contains(handle) }

    func block(_ handle: String) {
        guard !handle.isEmpty else { return }
        blockedHandles.insert(handle)
        defaults.set(Array(blockedHandles), forKey: Self.blockedKey)
        // A block is also an unfollow — see `follows`. Same frame, so the ring row, the follow
        // list and the Following count all drop them together with their posts.
        if follows?.isFollowing(handle) == true { follows?.toggle(handle) }
        // Server-side blocks are what actually enforce App Store 1.2 (RLS hides both directions);
        // the local set keeps the hide instant + covers seeded athletes with no server profile.
        let backend = backend
        Task { await backend?.setBlock(handle: handle, blocked: true) }
    }

    func unblock(_ handle: String) {
        blockedHandles.remove(handle)
        defaults.set(Array(blockedHandles), forKey: Self.blockedKey)
        let backend = backend
        Task { await backend?.setBlock(handle: handle, blocked: false) }
    }

    func isReported(_ id: UUID) -> Bool { reportedPosts.contains(id.uuidString) }

    /// Report a post/comment — hides it locally right away. (Local-only core; the reason-aware
    /// wrappers below also file the server-side report that review acts on.)
    func report(_ id: UUID) {
        reportedPosts.insert(id.uuidString)
        defaults.set(Array(reportedPosts), forKey: Self.reportedKey)
    }

    /// Report a post with its reason: instant local hide + the server audit row (App Store 1.2 —
    /// reviewed in the dashboard within 24h, docs/SOCIAL-BACKEND-SETUP.md).
    func reportPost(_ id: UUID, reason: ReportReason) {
        report(id)
        let backend = backend
        Task { await backend?.report(postID: id, commentID: nil, handle: nil, reason: reason, details: nil) }
    }

    /// Report a comment: instant local hide + the server audit row.
    func reportComment(_ id: UUID, reason: ReportReason) {
        report(id)
        let backend = backend
        Task { await backend?.report(postID: nil, commentID: id, handle: nil, reason: reason, details: nil) }
    }

    /// Report a whole ATHLETE: the server audit row plus a local block, which is what actually
    /// makes the dialog's promise ("we'll hide it from you") true.
    ///
    /// It used to walk `athlete.posts` and report each one. That set is the athlete's HAND-BUILT
    /// sample posts, not the ledger-materialized tiles their grid and the wall actually draw, so
    /// reporting someone hid a handful of posts and left the rest of their content exactly where
    /// it was (found 2026-08-29). Blocking hides by author handle, which is every surface at once.
    func reportAthlete(_ handle: String, reason: ReportReason) {
        guard !handle.isEmpty else { return }
        block(handle)
        let backend = backend
        Task { await backend?.report(postID: nil, commentID: nil, handle: handle, reason: reason, details: nil) }
    }

    /// Whether a feed item should be shown — not reported, and not from a blocked athlete.
    func isVisible(_ item: FeedItem) -> Bool {
        !isReported(item.id) && !(item.authorHandle.map(isBlocked) ?? false)
    }

    /// Whether a comment should be shown — not reported, and not from a blocked athlete.
    func isVisible(_ comment: Comment) -> Bool {
        !isReported(comment.id) && !(comment.authorHandle.map(isBlocked) ?? false)
    }
}

/// Why a post was reported — surfaced in the report dialog (App Store UGC expectation).
enum ReportReason: String, CaseIterable, Identifiable {
    case spam = "Spam or misleading"
    case inappropriate = "Inappropriate content"
    case harassment = "Harassment or hate"
    case other = "Something else"
    var id: String { rawValue }
}
