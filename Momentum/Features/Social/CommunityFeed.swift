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
    /// **Newest first, once.** The wall re-sorts this every time it assembles, and the directory
    /// hands its athletes back in generation order, so every assembly was a full random-order sort
    /// of ~2,900 fat `FeedItem`s. Sorting here instead makes the array one long descending run, and
    /// Swift's sort is adaptive: the wall's own re-sort (own posts + pulses merged on top) then
    /// costs a merge rather than a sort.
    private static let cached: [FeedItem] =
        CommunityDirectory.all().flatMap(\.posts).sorted { $0.date > $1.date }
}
