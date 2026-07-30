import Foundation

/// Deterministic, sample body-of-work for a **Momentum community** athlete so their profile renders
/// the same rich scaffold (discipline mix, consistency grid, trophy case) as a real athlete — clearly
/// community/sample content, never a claim about a real stranger (docs/SOCIAL-LAYER.md honest
/// presence). Seeded by handle so it's stable per launch and consistent between feed and profile.
extension CommunityAthlete {
    private var seed: Int {
        var h: UInt64 = 14695981039346656037
        for byte in handle.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return Int(bitPattern: UInt(truncatingIfNeeded: h))
    }

    var primaryType: WorkoutType { posts.first?.type ?? .run }

    /// A plausible discipline split totalling ~`totalWorkouts`, led by the athlete's primary sport
    /// with 1–2 deterministic secondaries (the hybrid-athlete shape).
    var disciplineCounts: [WorkoutType: Int] {
        var rng = SeededRNG(seed)
        let pool: [WorkoutType] = [.run, .ride, .strength, .walk, .swimming, .hiit, .rowing, .yoga]
        var types: [WorkoutType] = [primaryType]
        for _ in 0..<rng.int(1...2) {
            let t = rng.pick(pool)
            if !types.contains(t) { types.append(t) }
        }
        var out: [WorkoutType: Int] = [:]
        var remaining = max(types.count, totalWorkouts)
        for (index, type) in types.enumerated() {
            if index == types.count - 1 { out[type] = max(1, remaining); break }
            let share = max(1, Int(Double(remaining) * (index == 0 ? 0.55 : 0.5)))
            out[type] = share
            remaining -= share
        }
        return out
    }

    /// Active days across the last 16 weeks: the recent streak, then deterministic scatter reflecting
    /// overall volume.
    var consistencyDays: Set<Int> {
        let today = StreakCalculator.localDay(Date())
        let window = 16 * 7
        var days = Set<Int>()
        for d in 0..<min(dayStreak, window) { days.insert(today - d) }
        var rng = SeededRNG(seed &+ 7)
        let target = min(window - 1, max(dayStreak, min(80, totalWorkouts / 3)))
        var guardCount = 0
        while days.count < target && guardCount < 2000 {
            days.insert(today - rng.int(0...(window - 1)))
            guardCount += 1
        }
        return days
    }

    /// Per-active-day training minutes (seeded) so a visited grid shows the same stepped
    /// light/mid/full intensity as the athlete's own heatmap — a flat single-level grid was a
    /// generator tell. Mostly everyday sessions, with occasional big days hitting full intensity.
    var consistencyMinutes: [Int: Double] {
        var rng = SeededRNG(seed &+ 13)
        var out: [Int: Double] = [:]
        for day in consistencyDays.sorted() {   // sorted → deterministic rng-to-day mapping
            out[day] = rng.int(0...6) == 0 ? rng.double(80, 150) : rng.double(22, 74)
        }
        return out
    }

    /// The athlete's social graph — see `CommunityGraph`. The header count and the pushed list are
    /// the SAME data (the number you tap is literally the list's count), and the graph is a real
    /// graph: "A follows B" is one deterministic fact, so B's followers and A's following can never
    /// contradict each other (owner bar 2026-07-30: every community member has an actual account
    /// with real, consistent followers/following). Excludes the viewer; the header adds them.
    @MainActor var sampleFollowerCount: Int { CommunityGraph.followerHandles(of: handle).count }
    @MainActor var sampleFollowingCount: Int { CommunityGraph.followingHandles(of: handle).count }
    @MainActor func sampleFollowers() -> [CommunityAthlete] { CommunityGraph.resolve(CommunityGraph.followerHandles(of: handle)) }
    @MainActor func sampleFollowing() -> [CommunityAthlete] { CommunityGraph.resolve(CommunityGraph.followingHandles(of: handle)) }

    /// Lifetime time moving, derived so it can never contradict the athlete's other lifetime
    /// numbers (the 16-week heatmap minutes were briefly used here — 77 hours against 2,560 miles
    /// read as a generator tell, 2026-07-30): distance ÷ a sport-plausible seeded speed, plus the
    /// non-GPS share of sessions at everyday durations.
    var lifetimeDurationS: Double {
        var rng = SeededRNG(seed &+ 34)
        let speed: Double = {
            switch primaryType {
            case .ride: return rng.double(5.6, 7.8)          // 20–28 km/h
            case .walk: return rng.double(1.3, 1.6)
            case .swimming: return rng.double(0.9, 1.3)
            default: return rng.double(2.5, 3.3)             // run/trail: ~5:00–6:40 /km
            }
        }()
        let distanceTime = totalDistanceM > 0 ? totalDistanceM / speed : 0
        let gpsSessions = disciplineCounts.reduce(0) { $1.key.isGPS ? $0 + $1.value : $0 }
        let nonGPS = max(0, totalWorkouts - gpsSessions)
        return distanceTime + Double(nonGPS) * rng.double(42, 68) * 60
    }

    /// The athlete's trophy case, derived from the SAME numbers the rest of their profile shows —
    /// lifetime distance, longest run, streak, session count, strength mix, longest session — so
    /// the awards can never contradict the personal records beside them (owner call 2026-07-30:
    /// random award sets read as a generator tell). Ladders a sample athlete's numbers can't
    /// honestly evaluate (speed benchmarks, plan/training work, climb, big weeks, moments) are
    /// simply never claimed. Earned dates are seeded and ordered so higher tiers landed later.
    var communityAwards: (cells: [AwardsShelf.Cell], earnedCount: Int) {
        var rng = SeededRNG(seed &+ 55)
        let bests = personalRecords
        let runningPrimary = primaryType == .run || primaryType == .trailRun
        let strengthSessions = disciplineCounts.reduce(0) { $1.key.isStrengthStyle ? $0 + $1.value : $0 }

        // Each ladder: the catalog rungs in tier order, their thresholds, the ONE profile stat
        // they read, and how earned DATES are modeled. Adding a rung without its stat is how
        // contradictions start; a wrong date mode is how three medals land on the same day (the
        // clustered-dates tell, fixed 2026-07-30).
        enum DateMode { case accrual, streakDays, event }
        var ladders: [(ids: [String], needs: [Double], value: Double, mode: DateMode)] = []
        if runningPrimary {
            ladders.append((["distance.50", "distance.100", "distance.250", "distance.500",
                             "distance.1000", "distance.2500", "distance.5000"],
                            [50, 100, 250, 500, 1000, 2500, 5000], totalDistanceM / 1000, .accrual))
            ladders.append((["longrun.first", "longrun.5k", "longrun.10k", "longrun.half",
                             "longrun.marathon", "longrun.ultra"],
                            [1, 5_000, 10_000, 21_097.5, 42_195, 50_000], bests.longestRunM, .event))
        }
        if primaryType == .ride {
            ladders.append((["ride.100", "ride.500", "ride.1000", "ride.5000"],
                            [100, 500, 1000, 5000], totalDistanceM / 1000, .accrual))
        }
        ladders.append((["streak.7", "streak.14", "streak.30", "streak.60", "streak.100", "streak.365"],
                        [7, 14, 30, 60, 100, 365], Double(dayStreak), .streakDays))
        ladders.append((["sessions.10", "sessions.50", "sessions.100", "sessions.250",
                         "sessions.500", "sessions.1000"],
                        [10, 50, 100, 250, 500, 1000], Double(totalWorkouts), .accrual))
        if strengthSessions > 0 {
            ladders.append((["strength.first", "strength.10", "strength.50", "strength.100"],
                            [1, 10, 50, 100], Double(strengthSessions), .accrual))
        }
        ladders.append((["endurance.1h", "endurance.2h", "endurance.3h", "endurance.4h"],
                        [3600, 7200, 10800, 14400], bests.longestDurationS, .event))

        var earned: [(award: Award, at: Date)] = []
        var chase: [(award: Award, progress: Double)] = []
        let now = Date()
        // One seeded "career" per athlete: accrual medals date to when a steady accumulation
        // would actually have crossed each threshold, so spacing follows the real ratios.
        let careerDays = Double(rng.int(420...1100))
        for ladder in ladders {
            var eventDaysAgo = Double(rng.int(250...750))
            for (id, need) in zip(ladder.ids, ladder.needs) {
                guard let award = AwardsCatalog.award(id) else { continue }
                if ladder.value >= need {
                    let daysAgo: Double
                    switch ladder.mode {
                    case .accrual: daysAgo = max(3, careerDays * (1 - need / ladder.value))
                    case .streakDays: daysAgo = max(0.5, ladder.value - need)
                    case .event:
                        daysAgo = eventDaysAgo
                        eventDaysAgo = max(6, eventDaysAgo * rng.double(0.35, 0.65))
                    }
                    earned.append((award, now.addingTimeInterval(-daysAgo * 86_400)))
                } else {
                    if ladder.value > 0 { chase.append((award, min(0.97, ladder.value / need))) }
                    break   // tiers are ordered; the first miss ends the ladder
                }
            }
        }

        var cells: [AwardsShelf.Cell] = earned
            .sorted { $0.at > $1.at }
            .prefix(AwardsShelf.maxCells)
            .map { .init(award: $0.award, earnedAt: $0.at, progress: nil) }
        if cells.count < AwardsShelf.maxCells {
            cells += chase.sorted { $0.progress > $1.progress }
                .prefix(AwardsShelf.maxCells - cells.count)
                .map { .init(award: $0.award, earnedAt: nil, progress: $0.progress) }
        }
        return (cells, earned.count)
    }

    /// Sample bests shaped by the primary sport — lifters get e1RMs, distance athletes a long run.
    var personalRecords: (prs: [(name: String, e1RMKg: Double)], longestRunM: Double, longestDurationS: Double) {
        var rng = SeededRNG(seed &+ 21)
        if primaryType.isStrengthStyle {
            let lifts = ["Back Squat", "Bench Press", "Deadlift"]
            let prs = lifts.map { (name: $0, e1RMKg: Double(rng.int(60...210))) }
            return (prs, 0, Double(rng.int(35...80) * 60))
        }
        let isFoot = primaryType == .run || primaryType == .trailRun
        let longest = isFoot && totalDistanceM > 0
            ? min(42_195, max(5_000, totalDistanceM / Double(max(20, totalWorkouts)) * Double(rng.int(2...4))))
            : 0
        return ([], longest, Double(rng.int(40...150) * 60))
    }
}
