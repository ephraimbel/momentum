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
    /// Real athletes (Supabase) carry their avatar; seeded community renders initials.
    var avatarData: Data? = nil
    /// True for the seeded "Momentum community" (whose body-of-work is deterministic sample
    /// content); false for real network athletes — their profile shows only real data.
    var isSample: Bool = true
    var id: String { handle }
}

enum CommunityDirectory {
    // Generated once per launch (≈250 athletes) so the feed + globe are stable and not rebuilt on each
    // access. Featured (hand-curated) athletes lead; the generated community fills out the rest.
    private static let baseDate = Date()
    private static let cached: [CommunityAthlete] = featured(now: baseDate) + CommunityGenerator.generate(now: baseDate)

    static func all(now: Date = Date()) -> [CommunityAthlete] { cached }

    /// The hand-curated featured athletes (lead the feed; richer copy + globe spread).
    static func featured(now: Date = Date()) -> [CommunityAthlete] {
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        /// GPS posts take a REAL bundled loop nearest `targetKm` and derive their stat from its
        /// true length at `paceSecPerKm` (the map and the numbers agree); non-GPS posts pass a
        /// literal `stat`. City must match a `CommunityRoutes` key.
        func post(_ n: Int, _ a: CommunityAuthor, _ type: WorkoutType, _ when: Date, _ title: String,
                  _ caption: String?, _ stat: String = "", city: String? = nil,
                  targetKm: Double = 8, paceSecPerKm: Double = 340,
                  pr: String? = nil, reactions: Int = 0, ai: String? = nil) -> FeedItem {
            var rng = SeededRNG(n &* 99_173)
            let loop = type.isGPS
                ? (city ?? a.location).flatMap { CommunityRoutes.loop(city: $0, discipline: type, nearestKm: targetKm) }
                : nil
            let statLine = loop.map {
                let seconds = Int($0.km * paceSecPerKm + rng.double(0, 59))
                return String(format: "%.1f mi · %@", $0.km * 0.621371,
                              CommunityGenerator.durationString(seconds: seconds))
            } ?? stat
            let muscles = type.isStrengthStyle ? StrengthFeedMuscles.activation(forTitle: title, type: type) : nil
            let style = CommunityGenerator.feedStyles[n % CommunityGenerator.feedStyles.count]
            return FeedItem(id: pid(n), authorName: a.name, authorHandle: a.handle, location: a.location,
                            isCommunity: true, type: type, date: when, title: title, caption: caption,
                            statLine: statLine, prBadge: pr, muscles: muscles, routeLatLon: loop?.pts,
                            mapStyle: style, baseReactions: reactions, aiRead: ai)
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
                posts: [post(1, maya, .run, ago(1.5), "Sunrise tempo", "Negative split the whole way. Felt strong.", targetKm: 10, paceSecPerKm: 290, pr: "5K PR", reactions: 42, ai: "A textbook negative split — the back half was quicker at the same heart rate, which means real aerobic fitness is showing up, not just a good day.")]),
            CommunityAthlete(handle: theo.handle, name: theo.name, location: theo.location,
                bio: "Strength coach. Big believer in boring consistency.",
                totalWorkouts: 540, dayStreak: 9, totalDistanceM: 180_000, lat: 40.78, lon: -73.97,
                posts: [post(2, theo, .strength, ago(4), "Lower power", "Squats moving well at 3 plates.", "12,400 lb · 18 sets · 1:02:40", pr: "Squat e1RM PR", reactions: 67, ai: "Tonnage up with the same RPE — the new e1RM is earned, not a fluke. Hold this volume for a week before pushing load again.")]),
            CommunityAthlete(handle: lin.handle, name: lin.name, location: lin.location,
                bio: "Cyclist. Hills are just downhills in waiting.",
                totalWorkouts: 268, dayStreak: 5, totalDistanceM: 9_800_000, lat: 45.52, lon: -122.64,
                posts: [post(3, lin, .ride, ago(7), "Hill repeats", nil, targetKm: 39, paceSecPerKm: 139, reactions: 18)]),
            CommunityAthlete(handle: priya.handle, name: priya.name, location: priya.location,
                bio: "Hybrid athlete — lift heavy, move fast.",
                totalWorkouts: 190, dayStreak: 12, totalDistanceM: 620_000, lat: 51.51, lon: -0.13,
                posts: [post(4, priya, .hiit, ago(11), "Conditioning", "Quick and brutal.", "22:14", reactions: 9)]),
            CommunityAthlete(handle: marcus.handle, name: marcus.name, location: marcus.location,
                bio: "Swimmer. The water always tells the truth.",
                totalWorkouts: 221, dayStreak: 7, totalDistanceM: 540_000, lat: 25.77, lon: -80.25,
                posts: [post(5, marcus, .swimming, ago(20), "Pool intervals", "2km steady.", "38:42", reactions: 14)]),
            CommunityAthlete(handle: sofia.handle, name: sofia.name, location: sofia.location,
                bio: "Trail runner. Higher is better.",
                totalWorkouts: 156, dayStreak: 4, totalDistanceM: 1_900_000, lat: 40.01, lon: -105.27,
                posts: [post(6, sofia, .trailRun, ago(28), "Mesa loop", "Big climb, bigger views.", targetKm: 13, paceSecPerKm: 345, pr: "Longest run", reactions: 51)]),
            CommunityAthlete(handle: devon.handle, name: devon.name, location: devon.location,
                bio: "Erg every morning. Meters don't lie.",
                totalWorkouts: 410, dayStreak: 15, totalDistanceM: 2_400_000, lat: 41.88, lon: -87.63,
                posts: [post(7, devon, .rowing, ago(33), "Steady state", nil, "40:19", reactions: 7)]),
            CommunityAthlete(handle: amara.handle, name: amara.name, location: amara.location,
                bio: "Walking my way back to strong. One step at a time.",
                totalWorkouts: 88, dayStreak: 30, totalDistanceM: 410_000, lat: 47.62, lon: -122.31,
                posts: [post(8, amara, .walk, ago(46), "Recovery walk", "Easy day, clear head.", targetKm: 5, paceSecPerKm: 570, reactions: 23)]),
        ]
    }

    static func athlete(handle: String, now: Date = Date()) -> CommunityAthlete? {
        all(now: now).first { $0.handle == handle }
    }

    /// The posts shown on a visited SAMPLE athlete's profile grid: their feed post(s) plus a
    /// deterministic history (~10 weeks of training) so the grid reads like a real training log.
    /// Cached per handle — profiles open instantly on revisit. Real athletes never come through
    /// here; their grids show only what they actually shared.
    @MainActor private static var gridCache: [String: [FeedItem]] = [:]

    @MainActor
    static func gridPosts(for athlete: CommunityAthlete, now: Date = Date()) -> [FeedItem] {
        guard athlete.isSample else { return athlete.posts }
        if let cached = gridCache[athlete.handle] { return cached }
        var seed = SeededRNG(athlete.handle.utf8.reduce(3) { ($0 &* 61 &+ Int($1)) & 0xFFFF })
        let history = CommunityGenerator.historyPosts(
            handle: athlete.handle, name: athlete.name, city: athlete.location ?? "Austin",
            count: 11 + seed.int(0...7), now: now)
        let posts = (athlete.posts + history).sorted { $0.date > $1.date }
        gridCache[athlete.handle] = posts
        return posts
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

