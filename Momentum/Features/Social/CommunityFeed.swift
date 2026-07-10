import Foundation

/// The community feed = every seeded athlete's posts, flattened (docs/SOCIAL-LAYER.md). Source of
/// truth is `CommunityDirectory` so the feed and the athletes' profile pages can't diverge. Honest
/// presence: clearly-labeled community content, replaced by real network posts once Supabase is on.
enum CommunityFeed {
    static func seed(now: Date = Date()) -> [FeedItem] {
        CommunityDirectory.all(now: now).flatMap(\.posts)
    }
}
