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
