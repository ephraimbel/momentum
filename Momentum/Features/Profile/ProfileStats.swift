import Foundation

/// Aggregates profile analytics from history (PRD §4.8). Computed in memory from a fetched
/// `[Workout]` — no extra queries. PR shelves are derived on the fly until `PersonalRecord`
/// persistence is wired in the analytics pass.
@MainActor
struct ProfileStats {
    let currentStreak: Int
    let longestStreak: Int
    let totalWorkouts: Int
    let countsByType: [WorkoutType: Int]
    let totalDistanceM: Double
    let totalVolumeKg: Double
    let totalDurationS: Double
    let countingDays: Set<Int>
    let strengthPRs: [(name: String, e1RMKg: Double)]
    let longestRunM: Double
    let longestDurationS: Double

    /// `plan` feeds the rest-day half of the streak rule: days the plan deliberately leaves empty
    /// count, so following a 4-day/week plan perfectly never resets the streak on the weekend.
    init(workouts: [Workout], plan: TrainingPlan? = nil, calendar: Calendar = .current) {
        var counting = Set<Int>()
        var counts: [WorkoutType: Int] = [:]
        var distance = 0.0, volume = 0.0, duration = 0.0
        var bestE1RM: [String: Double] = [:]
        var longestRun = 0.0, longestDur = 0.0

        for w in workouts {
            counts[w.type, default: 0] += 1
            duration += w.durationS
            let dist = w.gps?.distanceM ?? 0
            distance += dist
            longestDur = max(longestDur, w.durationS)

            if StreakCalculator.workoutQualifies(type: w.type, distanceM: dist, activeSeconds: w.durationS) {
                counting.insert(StreakCalculator.localDay(w.startedAt, calendar: calendar))
            }

            if w.type.isStrengthStyle, let s = w.strength {
                volume += s.totalVolumeKg
                for row in s.exercises {
                    guard let name = row.exercise?.name else { continue }
                    for set in row.sets where set.isComplete && set.type == .working {
                        guard let kg = set.weightKg, let reps = set.reps else { continue }
                        bestE1RM[name] = max(bestE1RM[name] ?? 0, StrengthMath.e1RM(weightKg: kg, reps: reps))
                    }
                }
            } else if w.type == .run {
                longestRun = max(longestRun, dist)
            }
        }

        let today = StreakCalculator.localDay(Date(), calendar: calendar)
        // Planned rest days count toward the STREAK too (PRD §21) — otherwise every plan with two
        // adjacent rest days resets a perfectly-compliant athlete's streak. They stay out of
        // `countingDays` (the consistency heatmap shows days you actually moved).
        var streakDays = counting
        if let plan {
            let sessionDays = Set(plan.sessions.map { StreakCalculator.localDay($0.date, calendar: calendar) })
            streakDays.formUnion(StreakCalculator.plannedRestDays(sessionDays: sessionDays, today: today))
        }
        self.countingDays = counting
        self.currentStreak = StreakCalculator.currentStreak(countingDays: streakDays, today: today)
        self.longestStreak = StreakCalculator.longestStreak(countingDays: streakDays)
        self.totalWorkouts = workouts.count
        self.countsByType = counts
        self.totalDistanceM = distance
        self.totalVolumeKg = volume
        self.totalDurationS = duration
        self.strengthPRs = bestE1RM.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
        self.longestRunM = longestRun
        self.longestDurationS = longestDur
    }
}
