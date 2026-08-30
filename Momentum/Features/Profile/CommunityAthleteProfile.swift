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

    /// The sport they train. Their newest post is a real ledger entry now, so it is sometimes a
    /// cross-training day — `primarySport` keeps one gym session from re-reading a marathoner as
    /// a lifter across their bio, chips, grid mix and lifetime hero.
    var primaryType: WorkoutType { primarySport ?? posts.first?.type ?? .run }

    /// **The** derived body of work: one fold over this athlete's session ledger, cached per
    /// handle. Everything below reads it, which is what makes the trio, the lifetime cells, the
    /// discipline split, the heatmap and the trophy case incapable of contradicting each other or
    /// the tiles the grid draws.
    @MainActor var lifetime: CommunityLifetime { CommunityDirectory.lifetime(for: self) }

    /// The discipline split — counted from the sessions themselves, so the bars can only ever show
    /// sports that actually appear in the grid, in the proportions the grid shows them.
    @MainActor var disciplineCounts: [WorkoutType: Int] { lifetime.typeCounts }

    /// Every day they trained. The heatmap filters this to its 16-week window; because these are
    /// the ledger's own dates, an active square can only exist where a real session sits.
    @MainActor var consistencyDays: Set<Int> { lifetime.activeDays }

    /// Per-day training minutes — the sum of that day's actual session durations, so the stepped
    /// light/mid/full intensity of a square reflects the work the grid can show you.
    @MainActor var consistencyMinutes: [Int: Double] { lifetime.dayMinutes }

    /// The athlete's social graph — see `CommunityGraph`. The header count and the pushed list are
    /// the SAME data (the number you tap is literally the list's count), and the graph is a real
    /// graph: "A follows B" is one deterministic fact, so B's followers and A's following can never
    /// contradict each other (owner bar 2026-07-30: every community member has an actual account
    /// with real, consistent followers/following). Excludes the viewer; the header adds them.
    @MainActor var sampleFollowerCount: Int { CommunityGraph.followerHandles(of: handle).count }
    @MainActor var sampleFollowingCount: Int { CommunityGraph.followingHandles(of: handle).count }
    @MainActor func sampleFollowers() -> [CommunityAthlete] { CommunityGraph.resolve(CommunityGraph.followerHandles(of: handle)) }
    @MainActor func sampleFollowing() -> [CommunityAthlete] { CommunityGraph.resolve(CommunityGraph.followingHandles(of: handle)) }

    /// Lifetime time moving — the sum of every session's own duration. It used to be reverse-
    /// engineered from distance ÷ a seeded speed, which is how "77 hours against 2,560 miles"
    /// happened; there is nothing left to reverse-engineer now.
    @MainActor var lifetimeDurationS: Double { lifetime.durationS }

    /// The athlete's trophy case, derived from the SAME numbers the rest of their profile shows —
    /// lifetime distance, longest run, streak, session count, strength mix, longest session — so
    /// the awards can never contradict the personal records beside them (owner call 2026-07-30:
    /// random award sets read as a generator tell). Ladders a sample athlete's numbers can't
    /// honestly evaluate (speed benchmarks, plan/training work, climb, big weeks, moments) are
    /// simply never claimed. Earned dates are seeded and ordered so higher tiers landed later.
    @MainActor var communityAwards: (cells: [AwardsShelf.Cell], earnedCount: Int) {
        var rng = SeededRNG(seed &+ 55)
        let life = lifetime
        let runningPrimary = primaryType == .run || primaryType == .trailRun
        let strengthSessions = life.typeCounts.reduce(0) { $1.key.isStrengthStyle ? $0 + $1.value : $0 }

        // Each ladder: the catalog rungs in tier order, their thresholds, the ONE profile stat
        // they read, and how earned DATES are modeled. Adding a rung without its stat is how
        // contradictions start; a wrong date mode is how three medals land on the same day (the
        // clustered-dates tell, fixed 2026-07-30).
        enum DateMode { case accrual, streakDays, event }
        var ladders: [(ids: [String], needs: [Double], value: Double, mode: DateMode)] = []
        if runningPrimary {
            ladders.append((["distance.50", "distance.100", "distance.250", "distance.500",
                             "distance.1000", "distance.2500", "distance.5000"],
                            [50, 100, 250, 500, 1000, 2500, 5000], life.distanceM / 1000, .accrual))
            ladders.append((["longrun.first", "longrun.5k", "longrun.10k", "longrun.half",
                             "longrun.marathon", "longrun.ultra"],
                            [1, 5_000, 10_000, 21_097.5, 42_195, 50_000], life.longestFootM, .event))
        }
        if primaryType == .ride {
            ladders.append((["ride.100", "ride.500", "ride.1000", "ride.5000"],
                            [100, 500, 1000, 5000], life.distanceM / 1000, .accrual))
        }
        ladders.append((["streak.7", "streak.14", "streak.30", "streak.60", "streak.100", "streak.365"],
                        [7, 14, 30, 60, 100, 365], Double(life.streakDays), .streakDays))
        ladders.append((["sessions.10", "sessions.50", "sessions.100", "sessions.250",
                         "sessions.500", "sessions.1000"],
                        [10, 50, 100, 250, 500, 1000], Double(life.sessions), .accrual))
        if strengthSessions > 0 {
            ladders.append((["strength.first", "strength.10", "strength.50", "strength.100"],
                            [1, 10, 50, 100], Double(strengthSessions), .accrual))
        }
        ladders.append((["endurance.1h", "endurance.2h", "endurance.3h", "endurance.4h"],
                        [3600, 7200, 10800, 14400], life.longestDurationS, .event))

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

    /// Sample bests. The longest session and the longest run are the ledger's actual maxima — a
    /// "longest run" is now a real tile you can scroll to, not a multiple of an average. Only the
    /// lifters' e1RMs stay seeded: the ledger records that a strength session happened, never what
    /// was on the bar.
    @MainActor
    var personalRecords: (prs: [(name: String, e1RMKg: Double)], longestRunM: Double, longestDurationS: Double) {
        var rng = SeededRNG(seed &+ 21)
        let life = lifetime
        if primaryType.isStrengthStyle {
            let lifts = ["Back Squat", "Bench Press", "Deadlift"]
            let prs = lifts.map { (name: $0, e1RMKg: Double(rng.int(60...210))) }
            return (prs, 0, life.longestDurationS)
        }
        return ([], life.longestFootM, life.longestDurationS)
    }
}
