import Foundation

/// A seeded **Momentum community** athlete — a curated/official sample profile with its posts
/// (docs/SOCIAL-LAYER.md). Honest by design: clearly community content, never fake strangers. Both
/// the feed (their posts) and their profile page read from this one source. Replaced by real network
/// profiles once Supabase is configured.
struct CommunityAthlete: Identifiable, Sendable, Hashable {
    let handle: String
    let name: String
    let location: String?
    let bio: String
    let totalWorkouts: Int
    let dayStreak: Int
    let totalDistanceM: Double
    let lat: Double            // approximate home location for the globe (fuzzed — city-level)
    let lon: Double
    let posts: [FeedItem]
    var id: String { handle }
}

enum CommunityDirectory {
    static func all(now: Date = Date()) -> [CommunityAthlete] {
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        func post(_ n: Int, _ a: CommunityAuthor, _ type: WorkoutType, _ when: Date, _ title: String,
                  _ caption: String?, _ stat: String, pr: String? = nil, route: [CGPoint]? = nil) -> FeedItem {
            FeedItem(id: pid(n), authorName: a.name, authorHandle: a.handle, location: a.location,
                     isCommunity: true, type: type, date: when, title: title, caption: caption,
                     statLine: stat, prBadge: pr, routeNorm: route)
        }

        let maya = CommunityAuthor("mayaruns", "Maya Rivera", "Austin, TX")
        let theo = CommunityAuthor("coachtheo", "Theo Bennett", nil)
        let lin = CommunityAuthor("linrides", "Lin Chen", "Portland, OR")
        let priya = CommunityAuthor("priyalifts", "Priya N.", nil)
        let marcus = CommunityAuthor("marcusswims", "Marcus Hill", "Miami, FL")
        let sofia = CommunityAuthor("sofiatrails", "Sofia A.", "Boulder, CO")
        let devon = CommunityAuthor("devonrows", "Devon K.", nil)
        let amara = CommunityAuthor("amarawalks", "Amara O.", "Seattle, WA")

        return [
            CommunityAthlete(handle: maya.handle, name: maya.name, location: maya.location,
                bio: "Marathoner chasing a sub-3. Coffee, then miles.",
                totalWorkouts: 312, dayStreak: 21, totalDistanceM: 4_120_000, lat: 30.27, lon: -97.74,
                posts: [post(1, maya, .run, ago(1.5), "Sunrise tempo", "Negative split the whole way. Felt strong.", "6.2 mi · 48:10", pr: "5K PR", route: Routes.loop)]),
            CommunityAthlete(handle: theo.handle, name: theo.name, location: theo.location,
                bio: "Strength coach. Big believer in boring consistency.",
                totalWorkouts: 540, dayStreak: 9, totalDistanceM: 180_000, lat: 40.71, lon: -74.01,
                posts: [post(2, theo, .strength, ago(4), "Lower power", "Squats moving well at 3 plates.", "12,400 lb · 18 sets · 1:02", pr: "Squat e1RM PR")]),
            CommunityAthlete(handle: lin.handle, name: lin.name, location: lin.location,
                bio: "Cyclist. Hills are just downhills in waiting.",
                totalWorkouts: 268, dayStreak: 5, totalDistanceM: 9_800_000, lat: 45.52, lon: -122.68,
                posts: [post(3, lin, .ride, ago(7), "Hill repeats", nil, "24.3 mi · 1:31", route: Routes.wander)]),
            CommunityAthlete(handle: priya.handle, name: priya.name, location: priya.location,
                bio: "Hybrid athlete — lift heavy, move fast.",
                totalWorkouts: 190, dayStreak: 12, totalDistanceM: 620_000, lat: 51.51, lon: -0.13,
                posts: [post(4, priya, .hiit, ago(11), "Conditioning", "Quick and brutal.", "22:00")]),
            CommunityAthlete(handle: marcus.handle, name: marcus.name, location: marcus.location,
                bio: "Swimmer. The water always tells the truth.",
                totalWorkouts: 221, dayStreak: 7, totalDistanceM: 540_000, lat: 25.76, lon: -80.19,
                posts: [post(5, marcus, .swimming, ago(20), "Pool intervals", "2km steady.", "38:42")]),
            CommunityAthlete(handle: sofia.handle, name: sofia.name, location: sofia.location,
                bio: "Trail runner. Higher is better.",
                totalWorkouts: 156, dayStreak: 4, totalDistanceM: 1_900_000, lat: 40.01, lon: -105.27,
                posts: [post(6, sofia, .trailRun, ago(28), "Mesa loop", "Big climb, bigger views.", "8.0 mi · 1:14", pr: "Longest run", route: Routes.bigLoop)]),
            CommunityAthlete(handle: devon.handle, name: devon.name, location: devon.location,
                bio: "Erg every morning. Meters don't lie.",
                totalWorkouts: 410, dayStreak: 15, totalDistanceM: 2_400_000, lat: 41.88, lon: -87.63,
                posts: [post(7, devon, .rowing, ago(33), "Steady state", nil, "40:00")]),
            CommunityAthlete(handle: amara.handle, name: amara.name, location: amara.location,
                bio: "Walking my way back to strong. One step at a time.",
                totalWorkouts: 88, dayStreak: 30, totalDistanceM: 410_000, lat: 47.61, lon: -122.33,
                posts: [post(8, amara, .walk, ago(46), "Recovery walk", "Easy day, clear head.", "3.1 mi · 47:20")]),
        ]
    }

    static func athlete(handle: String, now: Date = Date()) -> CommunityAthlete? {
        all(now: now).first { $0.handle == handle }
    }

    private static func pid(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!
    }
}

private struct CommunityAuthor {
    let handle: String, name: String, location: String?
    init(_ handle: String, _ name: String, _ location: String?) {
        self.handle = handle; self.name = name; self.location = location
    }
}

/// Stylized normalized (0…1) routes for community silhouette banners.
private enum Routes {
    static let loop: [CGPoint] = [
        CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.35, y: 0.25), CGPoint(x: 0.6, y: 0.2),
        CGPoint(x: 0.8, y: 0.4), CGPoint(x: 0.75, y: 0.7), CGPoint(x: 0.5, y: 0.8),
        CGPoint(x: 0.3, y: 0.72), CGPoint(x: 0.2, y: 0.5)]
    static let wander: [CGPoint] = [
        CGPoint(x: 0.1, y: 0.7), CGPoint(x: 0.3, y: 0.55), CGPoint(x: 0.45, y: 0.62),
        CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.78, y: 0.45), CGPoint(x: 0.9, y: 0.25)]
    static let bigLoop: [CGPoint] = [
        CGPoint(x: 0.15, y: 0.6), CGPoint(x: 0.25, y: 0.3), CGPoint(x: 0.5, y: 0.15),
        CGPoint(x: 0.8, y: 0.3), CGPoint(x: 0.85, y: 0.6), CGPoint(x: 0.65, y: 0.85),
        CGPoint(x: 0.35, y: 0.82), CGPoint(x: 0.18, y: 0.7), CGPoint(x: 0.15, y: 0.6)]
}
