import Foundation

/// A deterministic, conservative starting-weight suggestion for a planned compound lift, from the
/// athlete's bodyweight, sex, and lifting experience (PRD §9 — rules-based; the AI only narrates).
/// Working-set weight (a hard set in the prescribed rep range), NOT a 1RM. Only suggested for barbell/
/// machine **compound** lifts — isolation/bodyweight/dumbbell-per-hand are too ambiguous to prescribe,
/// so those just show sets × reps. The athlete logs their real weight and the plan calibrates from there.
enum StrengthSuggest {

    /// Pure estimator (unit-tested): working weight in kg for a compound barbell/machine lift, else nil.
    static func estimate(primary: MuscleGroup?, category: ExerciseCategory, equipment: EquipmentType,
                         bodyMassKg: Double, female: Bool, level: ExperienceLevel) -> Double? {
        guard category == .compound, equipment == .barbell || equipment == .machine else { return nil }
        // Fraction of bodyweight for a male-novice working set, by movement pattern.
        let base: Double
        switch primary {
        case .quads, .hamstrings, .glutes: base = 0.70   // squat / deadlift / hinge family
        case .back:                        base = 0.55   // rows
        case .chest:                       base = 0.50   // bench / press
        case .shoulders:                   base = 0.35   // overhead press
        default:                           base = 0.45
        }
        let sexMult = female ? 0.62 : 1.0
        let expMult: Double = level == .new ? 1.0 : (level == .some ? 1.35 : 1.7)
        let kg = bodyMassKg * base * sexMult * expMult
        return max(10, (kg / 2.5).rounded() * 2.5)        // sane floor; round to nearest 2.5 kg
    }

    /// Suggested working weight (kg) for a planned exercise, or nil when we shouldn't prescribe one.
    static func workingKg(for ex: PlannedExercise, profile: UserProfile?) -> Double? {
        guard let e = ex.exercise else { return nil }
        return estimate(primary: e.primaryMuscles.compactMap(MuscleGroup.init(rawValue:)).first,
                        category: e.category, equipment: e.equipment,
                        bodyMassKg: profile?.bodyMassKg ?? 72.6,
                        female: profile?.sex == BiologicalSex.female.rawValue,
                        level: ExperienceLevel(rawValue: profile?.experience[Discipline.strength.rawValue] ?? "") ?? .some)
    }

    /// "~135 lb" / "~60 kg" for the prescribed working weight, or nil if none is suggested.
    static func label(for ex: PlannedExercise, profile: UserProfile?) -> String? {
        guard let kg = workingKg(for: ex, profile: profile) else { return nil }
        let unit = WeightUnit(rawValue: profile?.weightUnit ?? "kg") ?? .kg
        return "~\(Formatters.weight(kg: kg, unit: unit))"
    }
}
