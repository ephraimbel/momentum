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
    }

    func unblock(_ handle: String) {
        blockedHandles.remove(handle)
        defaults.set(Array(blockedHandles), forKey: Self.blockedKey)
    }

    func isReported(_ id: UUID) -> Bool { reportedPosts.contains(id.uuidString) }

    /// Report a post — hides it locally right away and (later) queues it server-side for review.
    func report(_ id: UUID) {
        reportedPosts.insert(id.uuidString)
        defaults.set(Array(reportedPosts), forKey: Self.reportedKey)
    }

    /// Whether a feed item should be shown — not reported, and not from a blocked athlete.
    func isVisible(_ item: FeedItem) -> Bool {
        !isReported(item.id) && !(item.authorHandle.map(isBlocked) ?? false)
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
