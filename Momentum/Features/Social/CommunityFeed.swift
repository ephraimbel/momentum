import Foundation

/// Seeded **Momentum community** content (docs/SOCIAL-LAYER.md — honest presence). Every item is
/// labeled as community content in the card; this is curated/official sample activity, never fake
/// strangers impersonating nearby users. It keeps the feed alive before/while real public posts
/// accrue, and is replaced by real network content once Supabase is configured.
enum CommunityFeed {
    static func seed(now: Date = Date()) -> [FeedItem] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

        return [
            FeedItem(id: id(1), authorName: "Maya Rivera", authorHandle: "mayaruns", location: "Austin, TX",
                     isCommunity: true, type: .run, date: ago(1.5),
                     title: "Sunrise tempo", caption: "Negative split the whole way. Felt strong.",
                     statLine: "6.2 mi · 48:10", prBadge: "5K PR", routeNorm: loop),
            FeedItem(id: id(2), authorName: "Theo Bennett", authorHandle: "coachtheo", location: nil,
                     isCommunity: true, type: .strength, date: ago(4),
                     title: "Lower power", caption: "Squats moving well at 3 plates.",
                     statLine: "12,400 lb · 18 sets · 1:02", prBadge: "Squat e1RM PR", routeNorm: nil),
            FeedItem(id: id(3), authorName: "Lin Chen", authorHandle: "linrides", location: "Portland, OR",
                     isCommunity: true, type: .ride, date: ago(7),
                     title: "Hill repeats", caption: nil,
                     statLine: "24.3 mi · 1:31", prBadge: nil, routeNorm: wander),
            FeedItem(id: id(4), authorName: "Priya N.", authorHandle: "priyalifts", location: nil,
                     isCommunity: true, type: .hiit, date: ago(11),
                     title: "Conditioning", caption: "Quick and brutal.",
                     statLine: "22:00", prBadge: nil, routeNorm: nil),
            FeedItem(id: id(5), authorName: "Marcus Hill", authorHandle: "marcusswims", location: "Miami, FL",
                     isCommunity: true, type: .swimming, date: ago(20),
                     title: "Pool intervals", caption: "2km steady.",
                     statLine: "38:42", prBadge: nil, routeNorm: nil),
            FeedItem(id: id(6), authorName: "Sofia A.", authorHandle: "sofiatrails", location: "Boulder, CO",
                     isCommunity: true, type: .trailRun, date: ago(28),
                     title: "Mesa loop", caption: "Big climb, bigger views.",
                     statLine: "8.0 mi · 1:14", prBadge: "Longest run", routeNorm: bigLoop),
            FeedItem(id: id(7), authorName: "Devon K.", authorHandle: "devonrows", location: nil,
                     isCommunity: true, type: .rowing, date: ago(33),
                     title: "Steady state", caption: nil,
                     statLine: "40:00", prBadge: nil, routeNorm: nil),
            FeedItem(id: id(8), authorName: "Amara O.", authorHandle: "amarawalks", location: "Seattle, WA",
                     isCommunity: true, type: .walk, date: ago(46),
                     title: "Recovery walk", caption: "Easy day, clear head.",
                     statLine: "3.1 mi · 47:20", prBadge: nil, routeNorm: wander),
        ]
    }

    // Stable IDs so the feed is deterministic across launches.
    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!
    }

    // A few stylized normalized routes for the silhouette banners.
    private static let loop: [CGPoint] = [
        CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.35, y: 0.25), CGPoint(x: 0.6, y: 0.2),
        CGPoint(x: 0.8, y: 0.4), CGPoint(x: 0.75, y: 0.7), CGPoint(x: 0.5, y: 0.8),
        CGPoint(x: 0.3, y: 0.72), CGPoint(x: 0.2, y: 0.5)
    ]
    private static let wander: [CGPoint] = [
        CGPoint(x: 0.1, y: 0.7), CGPoint(x: 0.3, y: 0.55), CGPoint(x: 0.45, y: 0.62),
        CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.78, y: 0.45), CGPoint(x: 0.9, y: 0.25)
    ]
    private static let bigLoop: [CGPoint] = [
        CGPoint(x: 0.15, y: 0.6), CGPoint(x: 0.25, y: 0.3), CGPoint(x: 0.5, y: 0.15),
        CGPoint(x: 0.8, y: 0.3), CGPoint(x: 0.85, y: 0.6), CGPoint(x: 0.65, y: 0.85),
        CGPoint(x: 0.35, y: 0.82), CGPoint(x: 0.18, y: 0.7), CGPoint(x: 0.15, y: 0.6)
    ]
}
