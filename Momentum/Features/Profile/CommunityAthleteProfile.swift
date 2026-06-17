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
