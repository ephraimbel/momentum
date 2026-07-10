import Foundation

/// Per-exercise progression analytics (PRD §4.8 — "e1RM curves"). Pure + deterministic: the engine
/// computes the series, the UI just draws it.
enum ExerciseTrends {
    struct Point: Equatable, Sendable { let date: Date; let e1RM: Double }

    /// Best working-set estimated-1RM per session for a named lift, oldest → newest. One point per
    /// workout that contains the lift (the session's top set), so the curve reads as progression.
    static func e1RMSeries(exerciseName: String, in workouts: [Workout]) -> [Point] {
        var points: [Point] = []
        for workout in workouts {
            guard let session = workout.strength else { continue }
            var best = 0.0
            for row in session.exercises where row.exercise?.name == exerciseName {
                for set in row.sets where set.isComplete && set.type == .working {
                    guard let kg = set.weightKg, let reps = set.reps, kg > 0, reps > 0 else { continue }
                    best = max(best, StrengthMath.e1RM(weightKg: kg, reps: reps))
                }
            }
            if best > 0 { points.append(Point(date: workout.startedAt, e1RM: best)) }
        }
        return points.sorted { $0.date < $1.date }
    }

    /// Percent change from the first to the most recent session in a series (0 if <2 points).
    static func gainPercent(_ series: [Point]) -> Double {
        guard let first = series.first?.e1RM, let last = series.last?.e1RM, first > 0, series.count >= 2
        else { return 0 }
        return (last - first) / first * 100
    }
}
