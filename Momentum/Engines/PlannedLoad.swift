import Foundation

/// Estimated load for a session that hasn't happened yet (Health hub §11.1.1) — the planned twin of
/// `TrainingLoad.session`, same Foster convention (`minutes × RPE 1–10`), so ghost bars on the
/// balance chart, the race-day Form projection, and the pre-week planned-vs-actual ACWR recheck all
/// speak the completed-load currency. Minutes come from the prescription (`targetDurationS`, else
/// distance × pace); a run's intensity is how hard it's *meant* to feel (`EffortAdaptation.expectedRPE`);
/// strength prescribes sets, not minutes, so it approximates ~3 working minutes per set at RPE 6.
/// Distance-only sessions fall back to `km × 6` — the exact fallback line in `TrainingLoad.session`.
enum PlannedLoad {
    /// Pure snapshot of a `PlannedSession` — computation never touches the SwiftData model.
    struct Input: Sendable {
        var runType: RunType?
        var targetDistanceM: Double?
        var targetDurationS: Double?
        var targetPaceSPerKm: Double?
        var strengthSets: Int = 0        // Σ targetSets across the session's exercises
        /// Cardio intensity when there's no `runType` — `TrainingLoad.defaultIntensity` convention.
        var fallbackIntensity: Int = 5
    }

    static func estimate(_ s: Input) -> Double {
        // Strength: ~3 working minutes per set (lift + rest) at a steady RPE 6.
        if s.strengthSets > 0 { return Double(s.strengthSets) * 3 * 6 }
        let intensity = Double(s.runType.map(EffortAdaptation.expectedRPE) ?? s.fallbackIntensity)
        if let dur = s.targetDurationS, dur > 0 { return dur / 60 * intensity }
        guard let dist = s.targetDistanceM, dist > 0 else { return 0 }
        if let pace = s.targetPaceSPerKm, pace > 0 { return (dist / 1000) * (pace / 60) * intensity }
        return (dist / 1000) * 6   // distance-only fallback, mirrors TrainingLoad.session
    }

    /// Convenience for call sites holding the model.
    static func estimate(_ session: PlannedSession) -> Double { estimate(Input(session)) }
}

extension PlannedLoad.Input {
    /// Snapshot the model's prescription fields into pure inputs.
    init(_ session: PlannedSession) {
        self.init(runType: session.runType,
                  targetDistanceM: session.targetDistanceM,
                  targetDurationS: session.targetDurationS,
                  targetPaceSPerKm: session.targetPaceSPerKm,
                  strengthSets: session.strengthTargets.reduce(0) { $0 + $1.targetSets },
                  fallbackIntensity: TrainingLoad.defaultIntensity(session.workoutType ?? Self.sport(of: session.discipline)))
    }

    /// Representative sport per discipline when no exact `sportType` was planned.
    private static func sport(of d: Discipline) -> WorkoutType {
        switch d {
        case .running: .run
        case .cycling: .ride
        case .walking: .walk
        case .strength: .strength
        }
    }
}
