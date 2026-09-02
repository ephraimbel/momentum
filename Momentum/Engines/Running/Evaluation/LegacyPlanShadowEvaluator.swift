import Foundation

struct LegacyPlanEvaluationResult: Sendable {
    var plannerVersion: String
    var candidate: GeneratedPlan
    var snapshot: PlanSemanticSnapshot
    var digest: PlanSemanticDigest
    var validation: PlanValidationReport
    var differenceFromBaseline: PlanSemanticDiff?
    var replay: LegacyPlanReplay
    var expectedDigestMatches: Bool?
}

/// Stage-A shadow entry point. Its signature accepts only value snapshots and returns only values;
/// there is deliberately no `ModelContext`, service or persistence callback to misuse.
enum LegacyPlanShadowEvaluator {
    static func evaluate(inputs: PlanInputs,
                         catalog: [ExerciseCatalogItem],
                         calibration: CalibrationSeed = .none,
                         startDate: Date,
                         calendar: Calendar = .current,
                         baseline: GeneratedPlan? = nil) throws -> LegacyPlanEvaluationResult {
        let candidate = PlanEngine.generate(
            profile: inputs,
            catalog: catalog,
            calibration: calibration,
            startDate: startDate,
            calendar: calendar
        )
        let snapshot = candidate.semanticSnapshot()
        let digest = try snapshot.digest()
        let validation = LegacyPlanInvariantValidator.validate(
            candidate,
            inputs: inputs,
            calibration: calibration,
            startDate: startDate,
            calendar: calendar
        )
        let difference = try baseline.map { try PlanSemanticDiffer.compare($0, candidate) }
        let replay = LegacyPlanReplay(
            inputs: inputs,
            catalog: catalog,
            calibration: calibration,
            startDate: startDate,
            calendar: calendar,
            expectedDigest: digest
        )
        return LegacyPlanEvaluationResult(
            plannerVersion: LegacyPlanReplay.currentPlannerVersion,
            candidate: candidate,
            snapshot: snapshot,
            digest: digest,
            validation: validation,
            differenceFromBaseline: difference,
            replay: replay,
            expectedDigestMatches: nil
        )
    }

    static func evaluate(replay: LegacyPlanReplay,
                         baseline: GeneratedPlan? = nil) throws -> LegacyPlanEvaluationResult {
        let inputs = try replay.replayInputs()
        let catalog = try replay.replayCatalog()
        let calibration = try replay.replayCalibration()
        let calendar = try replay.replayCalendar()
        let startDate = Date(timeIntervalSinceReferenceDate: replay.startReferenceSeconds)
        let candidate = PlanEngine.generate(
            profile: inputs,
            catalog: catalog,
            calibration: calibration,
            startDate: startDate,
            calendar: calendar
        )
        let snapshot = candidate.semanticSnapshot()
        let digest = try snapshot.digest()
        let validation = LegacyPlanInvariantValidator.validate(
            candidate,
            inputs: inputs,
            calibration: calibration,
            startDate: startDate,
            calendar: calendar
        )
        return LegacyPlanEvaluationResult(
            plannerVersion: replay.plannerVersion,
            candidate: candidate,
            snapshot: snapshot,
            digest: digest,
            validation: validation,
            differenceFromBaseline: try baseline.map { try PlanSemanticDiffer.compare($0, candidate) },
            replay: replay,
            expectedDigestMatches: replay.expectedDigest.map { $0 == digest }
        )
    }
}
