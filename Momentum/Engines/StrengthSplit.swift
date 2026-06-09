import Foundation

/// Deterministic split naming for a strength session — turns the muscles worked into a friendly
/// default title ("Push Day", "Pull Day", "Leg Day", "Upper Body", "Full Body", "Core"). Rules-based
/// and testable; the AI never names workouts.
enum StrengthSplit {
    private static let push: Set<MuscleGroup> = [.chest, .shoulders, .triceps]
    private static let pull: Set<MuscleGroup> = [.back, .biceps, .forearms]
    private static let legs: Set<MuscleGroup> = [.quads, .hamstrings, .glutes, .calves]

    /// Classify from working-sets-by-muscle (primary 1.0 / secondary 0.5, per `StrengthMath`).
    static func title(forSetsByMuscle sets: [MuscleGroup: Double]) -> String {
        func sum(_ group: Set<MuscleGroup>) -> Double {
            sets.reduce(0) { group.contains($1.key) ? $0 + $1.value : $0 }
        }
        let p = sum(push), l = sum(pull), g = sum(legs)
        let core = sets[.core] ?? 0
        let full = sets[.fullBody] ?? 0
        let classified = p + l + g

        guard classified > 0 else {
            if full > 0 { return "Full Body" }
            return core > 0 ? "Core" : "Strength"
        }
        if full >= classified { return "Full Body" }

        // A single bucket dominating reads as that focused day.
        if p / classified >= 0.65 { return "Push Day" }
        if l / classified >= 0.65 { return "Pull Day" }
        if g / classified >= 0.65 { return "Leg Day" }

        let hasUpper = (p + l) > 0
        let hasLegs = g > 0
        if hasUpper && hasLegs { return "Full Body" }
        if hasUpper { return "Upper Body" }
        return "Leg Day"
    }

    /// Convenience over a `StrengthSession`'s completed working sets.
    @MainActor
    static func title(for session: StrengthSession) -> String {
        let entries = session.exercises.map { row in
            (primary: (row.exercise?.primaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             secondary: (row.exercise?.secondaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             sets: row.sets.filter { $0.isComplete && $0.type == .working }.count)
        }
        return title(forSetsByMuscle: StrengthMath.weeklySetsByMuscle(entries))
    }

    /// The intended split for a planned session (from its prescribed targets) — used so a
    /// half-finished "Push Day" still names itself after the plan.
    @MainActor
    static func title(forPlanned session: PlannedSession) -> String {
        let entries = session.strengthTargets.map { pe in
            (primary: (pe.exercise?.primaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             secondary: (pe.exercise?.secondaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             sets: max(1, pe.targetSets))
        }
        return title(forSetsByMuscle: StrengthMath.weeklySetsByMuscle(entries))
    }
}
