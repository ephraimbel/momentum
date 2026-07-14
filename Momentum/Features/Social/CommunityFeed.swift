import Foundation

/// The community feed = every seeded athlete's posts, flattened (docs/SOCIAL-LAYER.md). Source of
/// truth is `CommunityDirectory` so the feed and the athletes' profile pages can't diverge. Honest
/// presence: clearly-labeled community content, replaced by real network posts once Supabase is on.
enum CommunityFeed {
    /// Flattened once and held. `CommunityDirectory.all()` is launch-cached and its posts are
    /// immutable within a process (the daily rotation is baked into the identities at launch), so
    /// re-flattening ~950 athletes on every feed reassembly — which happens on each Community tab
    /// revisit — was pure main-thread waste. Memoized so entering the tab never re-allocates the
    /// whole post list. (`now` was already ignored: `all(now:)` returns the launch cache regardless.)
    static func seed(now: Date = Date()) -> [FeedItem] { cached }
    private static let cached: [FeedItem] = CommunityDirectory.all().flatMap(\.posts)
}
