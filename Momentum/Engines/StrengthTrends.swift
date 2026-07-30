import Foundation

/// Pro strength-progression analytics — the numeric series behind the Trends page's lifting layer.
/// Pure + deterministic, all SI (kg). Builds on `ExerciseTrends` (per-lift e1RM curves),
/// `StrengthMath`, and `MuscleActivation` (weighted sets by muscle) — data the app logs on every
/// set but never charted over time.
enum StrengthTrends {

    /// A headline lift's progression, for a vitals tile: current estimated 1RM, its gain since the
    /// first logged session, and the e1RM values for a sparkline.
    struct LiftMetric: Identifiable, Equatable, Sendable {
        let name: String
        let currentE1RMKg: Double
        let gainPct: Double
        let spark: [Double]       // e1RM per session, oldest → newest
        let sessions: Int
        var id: String { name }
    }

    /// One muscle's share of recent working-set volume (primary 1.0, secondary 0.5).
    struct MuscleLoad: Identifiable, Equatable, Sendable {
        let muscle: MuscleGroup
        let sets: Double
        var id: String { muscle.rawValue }
    }

    // MARK: Top lifts

    /// Lift names ranked by how many sessions worked them (staples first) — the lifts worth
    /// charting. `minSessions` (default 2) keeps out one-off lifts that can't show a curve.
    static func topLifts(in workouts: [Workout], limit: Int = 6, minSessions: Int = 2) -> [String] {
        var sessionCount: [String: Int] = [:]
        var lastSeen: [String: Date] = [:]
        for w in workouts {
            guard let session = w.strength else { continue }
            var namesThisSession = Set<String>()
            for row in session.exercises {
                guard let name = row.exercise?.name, !name.isEmpty else { continue }
                let hasWorkingSet = row.sets.contains { $0.isComplete && $0.type == .working && ($0.weightKg ?? 0) > 0 }
                if hasWorkingSet { namesThisSession.insert(name) }
            }
            for name in namesThisSession {
                sessionCount[name, default: 0] += 1
                lastSeen[name] = max(lastSeen[name] ?? w.startedAt, w.startedAt)
            }
        }
        return sessionCount
            .filter { $0.value >= minSessions }
            .sorted { a, b in
                a.value != b.value ? a.value > b.value : (lastSeen[a.key] ?? .distantPast) > (lastSeen[b.key] ?? .distantPast)
            }
            .prefix(limit)
            .map(\.key)
    }

    /// The vitals tiles for the top lifts — current e1RM, gain, and a sparkline each.
    static func liftSummary(in workouts: [Workout], limit: Int = 4) -> [LiftMetric] {
        topLifts(in: workouts, limit: limit).compactMap { name in
            let series = ExerciseTrends.e1RMSeries(exerciseName: name, in: workouts)
            guard let last = series.last?.e1RM, last > 0 else { return nil }
            return LiftMetric(name: name, currentE1RMKg: last,
                              gainPct: ExerciseTrends.gainPercent(series),
                              spark: series.map(\.e1RM), sessions: series.count)
        }
    }

    // MARK: Weekly volume

    /// Weekly working-set volume (Σ weight·reps, kg) over `weeks` rolling 7-day windows, oldest →
    /// newest. Empty weeks read 0 so the timeline never has gaps.
    static func weeklyVolume(in workouts: [Workout], weeks: Int = 12,
                             now: Date = Date(), calendar: Calendar = .current) -> [TrendAnalytics.WeekValue] {
        let today = calendar.startOfDay(for: now)
        return (0..<weeks).reversed().compactMap { i -> TrendAnalytics.WeekValue? in
            guard let end = calendar.date(byAdding: .day, value: -7 * i, to: today),
                  let start = calendar.date(byAdding: .day, value: -7, to: end) else { return nil }
            var volume = 0.0
            for w in workouts where w.startedAt > start && w.startedAt <= end {
                guard let session = w.strength else { continue }
                for row in session.exercises {
                    for set in row.sets where set.isComplete && set.type == .working {
                        if let kg = set.weightKg, let reps = set.reps {
                            volume += StrengthMath.setVolume(weightKg: kg, reps: reps)
                        }
                    }
                }
            }
            return TrendAnalytics.WeekValue(weekStart: start, value: volume)
        }
    }

    // MARK: Muscle balance

    /// Weighted working sets per muscle over the trailing `days` (default 28) — sorted heaviest →
    /// lightest so the neglected groups surface at the bottom. Empty when no strength history.
    static func muscleBalance(in workouts: [Workout], days: Int = 28,
                              now: Date = Date(), calendar: Calendar = .current) -> [MuscleLoad] {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return [] }
        let recent = workouts.filter { $0.type.isStrengthStyle && $0.startedAt >= cutoff }
        return MuscleActivation.from(workouts: recent)
            .filter { $0.value > 0 }
            .map { MuscleLoad(muscle: $0.key, sets: $0.value) }
            .sorted { $0.sets > $1.sets }
    }
}
