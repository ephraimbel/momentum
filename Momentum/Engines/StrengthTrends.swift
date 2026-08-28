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
        /// The equipment the lift was last logged on (the progression row's subtitle).
        var equipment: EquipmentType? = nil
        var id: String { name }
    }

    /// The six body regions of the muscle-load wheel (2026-08-28, the Bevel "Total Volume" /
    /// "Muscular Load" read in our theme). Clockwise from the top: chest, back, legs,
    /// shoulders, core, arms — the same order Bevel lays them out, so the eye reads it the same.
    enum BodyRegion: String, CaseIterable, Identifiable, Sendable {
        case chest, back, legs, shoulders, core, arms
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
        /// Which region a muscle belongs to (`.fullBody` spreads across all six).
        static func of(_ m: MuscleGroup) -> BodyRegion? {
            switch m {
            case .chest: .chest
            case .back: .back
            case .shoulders: .shoulders
            case .biceps, .triceps, .forearms: .arms
            case .quads, .hamstrings, .glutes, .calves: .legs
            case .core: .core
            case .fullBody: nil
            }
        }
    }

    /// One region's recent training: weight moved (kg, working sets) and weighted working
    /// sets — the same primary-1.0 / secondary-0.5 credit the muscle map grades the body by, so
    /// the wheel and the figure always agree on which part of the body is carrying the load.
    struct RegionLoad: Identifiable, Equatable, Sendable {
        let region: BodyRegion
        let volumeKg: Double
        let sets: Double
        var id: String { region.rawValue }
    }

    /// One logged exercise's contribution, as the region walk sees it.
    struct RegionEntry: Sendable {
        let primary: [MuscleGroup]
        let secondary: [MuscleGroup]
        let volumeKg: Double
        let workingSets: Double
    }

    /// Pure aggregation. Volume is never double-counted: each set's weight·reps is SHARED across
    /// the muscles it works (primary weight 1.0, secondary 0.5, normalized), so the six regions
    /// sum to the total moved. Sets are credited the muscle-map way (1.0 / 0.5, un-normalized).
    static func regionLoads(entries: [RegionEntry]) -> [RegionLoad] {
        var volume: [BodyRegion: Double] = [:]
        var sets: [BodyRegion: Double] = [:]
        for e in entries {
            var weights: [BodyRegion: Double] = [:]
            func credit(_ m: MuscleGroup, _ w: Double) {
                if let r = BodyRegion.of(m) { weights[r, default: 0] += w }
                else { for r in BodyRegion.allCases { weights[r, default: 0] += w / 6 } }
            }
            for m in e.primary { credit(m, 1.0) }
            for m in e.secondary { credit(m, 0.5) }
            let total = weights.values.reduce(0, +)
            guard total > 0 else { continue }
            for (r, w) in weights {
                volume[r, default: 0] += e.volumeKg * (w / total)
                sets[r, default: 0] += e.workingSets * w
            }
        }
        return BodyRegion.allCases.map {
            RegionLoad(region: $0, volumeKg: volume[$0] ?? 0, sets: sets[$0] ?? 0)
        }
    }

    /// The wheel's data over the trailing `days` — every region, zeros included, in wheel order.
    static func regionLoads(in workouts: [Workout], days: Int = 30,
                            now: Date = Date(), calendar: Calendar = .current) -> [RegionLoad] {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return [] }
        var entries: [RegionEntry] = []
        for w in workouts where w.type.isStrengthStyle && w.startedAt >= cutoff {
            guard let session = w.strength else { continue }
            for row in session.exercises {
                guard let ex = row.exercise else { continue }
                let working = row.sets.filter { $0.isComplete && $0.type == .working }
                guard !working.isEmpty else { continue }
                let volume = working.reduce(0.0) { acc, set in
                    guard let kg = set.weightKg, let reps = set.reps else { return acc }
                    return acc + StrengthMath.setVolume(weightKg: kg, reps: reps)
                }
                entries.append(RegionEntry(primary: ex.primaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                                           secondary: ex.secondaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                                           volumeKg: volume, workingSets: Double(working.count)))
            }
        }
        return regionLoads(entries: entries)
    }

    /// Every lift with a logged working set, staples first — the Strength Progression rows.
    /// `minSessions` 1: a lift logged once still earns a row (its line is flat until the next).
    static func progression(in workouts: [Workout], limit: Int = 6) -> [LiftMetric] {
        var equipmentByName: [String: EquipmentType] = [:]
        for w in workouts {
            guard let session = w.strength else { continue }
            for row in session.exercises {
                if let ex = row.exercise, !ex.name.isEmpty { equipmentByName[ex.name] = ex.equipment }
            }
        }
        return topLifts(in: workouts, limit: limit, minSessions: 1).compactMap { name in
            let series = ExerciseTrends.e1RMSeries(exerciseName: name, in: workouts)
            guard let last = series.last?.e1RM, last > 0 else { return nil }
            return LiftMetric(name: name, currentE1RMKg: last,
                              gainPct: ExerciseTrends.gainPercent(series),
                              spark: series.map(\.e1RM), sessions: series.count,
                              equipment: equipmentByName[name])
        }
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
