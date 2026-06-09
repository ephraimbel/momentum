import Foundation

/// Pure strength calculations (PRD §9.2, §22). All inputs in kg. Value-typed for testability;
/// engines map their `SetEntry` rows onto `WorkingSet` before calling.
enum StrengthMath {
    struct WorkingSet: Equatable, Sendable {
        let weightKg: Double
        let reps: Int
    }

    /// Estimated 1-rep max (Epley): `weight · (1 + reps/30)`.
    static func e1RM(weightKg: Double, reps: Int) -> Double {
        guard reps > 0, weightKg > 0 else { return 0 }
        return weightKg * (1 + Double(reps) / 30)
    }

    /// Volume of a single set.
    static func setVolume(weightKg: Double, reps: Int) -> Double {
        max(0, weightKg) * Double(max(0, reps))
    }

    /// Total working-set volume (warmups already excluded by the caller).
    static func sessionVolume(_ sets: [WorkingSet]) -> Double {
        sets.reduce(0) { $0 + setVolume(weightKg: $1.weightKg, reps: $1.reps) }
    }

    /// Heaviest weight lifted across the given sets.
    static func heaviestWeight(_ sets: [WorkingSet]) -> Double {
        sets.map(\.weightKg).max() ?? 0
    }

    /// Best estimated 1RM across the given sets.
    static func bestE1RM(_ sets: [WorkingSet]) -> Double {
        sets.map { e1RM(weightKg: $0.weightKg, reps: $0.reps) }.max() ?? 0
    }

    /// Best single-set volume.
    static func bestSetVolume(_ sets: [WorkingSet]) -> Double {
        sets.map { setVolume(weightKg: $0.weightKg, reps: $0.reps) }.max() ?? 0
    }

    /// Best weight achieved at each exact rep count (the rep-max table).
    static func repMaxes(_ sets: [WorkingSet]) -> [Int: Double] {
        var table: [Int: Double] = [:]
        for s in sets where s.reps > 0 {
            table[s.reps] = max(table[s.reps] ?? 0, s.weightKg)
        }
        return table
    }

    /// Weekly working sets per muscle (PRD §22): primary credits 1.0, secondary 0.5.
    /// `entries` = (primaryMuscles, secondaryMuscles, workingSetCount) over the trailing 7 days.
    static func weeklySetsByMuscle(
        _ entries: [(primary: [MuscleGroup], secondary: [MuscleGroup], sets: Int)]
    ) -> [MuscleGroup: Double] {
        var totals: [MuscleGroup: Double] = [:]
        for e in entries {
            for m in e.primary { totals[m, default: 0] += Double(e.sets) }
            for m in e.secondary { totals[m, default: 0] += 0.5 * Double(e.sets) }
        }
        return totals
    }
}
