import Foundation
import Testing
@testable import Momentum

struct ExecutionPrescriptionTests {
    @Test func versionedPayloadRoundTripsTheCompleteExecutionContract() throws {
        let legacy = legacyFields()
        let workout = StructuredWorkout(title: "4×400m", steps: [
            WorkoutStep(kind: .warmup, target: .distance(1_000), paceSPerKm: 360),
            WorkoutStep(kind: .work, target: .distance(400), paceSPerKm: 250,
                        repIndex: 1, repTotal: 4),
            WorkoutStep(kind: .recovery, target: .duration(90), paceSPerKm: 390),
        ])
        let prescription = ExecutionPrescriptionBuilder.build(
            planID: "plan-1",
            sessionID: "session-1",
            intent: intent(),
            legacy: legacy,
            structuredWorkout: workout
        )
        #expect(prescription.validationIssues.isEmpty)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(prescription)
        let resolved = ExecutionPrescriptionResolver.resolve(data, legacyFallback: fallbackFields())
        #expect(resolved.source == .versioned)
        #expect(resolved.prescription == prescription)
        #expect(resolved.legacy == legacy)
        #expect(resolved.structuredWorkout == workout)
        #expect(resolved.target?.hierarchy.primary == .intervalStructure)
        #expect(resolved.purpose == "Develop controlled speed without racing the workout.")

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["futurePhoneField"] = ["safe": true]
        let futureData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let futureResolved = ExecutionPrescriptionResolver.resolve(futureData, legacyFallback: fallbackFields())
        #expect(futureResolved.source == .versioned)
        #expect(futureResolved.prescription == prescription)
    }

    @Test func missingMalformedUnsupportedAndInvalidPayloadsUseExactLegacyFallback() throws {
        let fallback = fallbackFields()
        let missing = ExecutionPrescriptionResolver.resolve(nil, legacyFallback: fallback)
        #expect(missing.source == .legacyMissingPayload)
        #expect(missing.legacy == fallback)
        #expect(missing.prescription == nil)

        let malformed = ExecutionPrescriptionResolver.resolve(Data("{".utf8), legacyFallback: fallback)
        #expect(malformed.source == .legacyMalformedPayload)
        #expect(malformed.legacy == fallback)

        let unsupported = ExecutionPrescriptionResolver.resolve(
            Data("{\"schemaVersion\":99}".utf8), legacyFallback: fallback
        )
        #expect(unsupported.source == .legacyUnsupportedVersion)
        #expect(unsupported.legacy == fallback)

        let invalid = ExecutionPrescription(
            schemaVersion: ExecutionPrescription.currentSchemaVersion,
            planID: "",
            sessionID: "session-1",
            intentID: nil,
            intentVersion: nil,
            target: ExecutionTargetContract(
                hierarchy: ExecutionTargetHierarchy(primary: .distance),
                distanceM: nil,
                durationS: nil,
                paceSPerKm: nil,
                effortCue: nil,
                intervalPrescription: nil,
                recoveryDistanceM: nil,
                recoveryDurationS: nil,
                recoveryMode: nil,
                successRange: nil
            ),
            legacy: legacyFields(),
            structuredWorkout: nil,
            purpose: "Invalid fixture"
        )
        #expect(Set(invalid.validationIssues) == [.missingStableIdentifier, .missingPrimaryTarget])
        let invalidResolved = ExecutionPrescriptionResolver.resolve(
            try JSONEncoder().encode(invalid), legacyFallback: fallback
        )
        #expect(invalidResolved.source == .legacyInvalidPayload)
        #expect(invalidResolved.legacy == fallback)
    }

    @Test func persistedIntentBuildsTypedPayloadAndUnknownSidecarFallsBackSafely() {
        let plan = TrainingPlan()
        plan.id = id(1)
        let session = PlannedSession()
        session.id = id(2)
        session.discipline = .running
        session.runType = .tempo
        session.targetDistanceM = 8_000
        session.targetDurationS = 2_720
        session.targetPaceSPerKm = 340
        session.intervals = "20 min controlled"
        let persisted = record(primary: RunningTargetKind.pace.rawValue)

        let typed = ExecutionPrescriptionBuilder.build(
            plan: plan,
            session: session,
            intentRecord: persisted,
            structuredWorkout: nil
        )
        #expect(typed.validationIssues.isEmpty)
        #expect(typed.intentID == persisted.id)
        #expect(typed.target.hierarchy.primary == .pace)
        #expect(typed.target.hierarchy.fallbacks == [.effort])
        #expect(typed.target.successRange == ExecutionValueRange(lower: 330, upper: 350))
        #expect(typed.purpose == "Build controlled threshold endurance.")

        let unknown = record(primary: "future-target-kind")
        let safe = ExecutionPrescriptionBuilder.build(
            plan: plan,
            session: session,
            intentRecord: unknown,
            structuredWorkout: nil
        )
        #expect(safe.validationIssues.isEmpty)
        #expect(safe.intentID == nil)
        #expect(safe.target.hierarchy.primary == .intervalStructure)
        #expect(safe.legacy.targetDistanceM == session.targetDistanceM)
        #expect(safe.legacy.intervalPrescription == session.intervals)
    }

    @Test func invalidStructuredStepsAreRejectedBeforeTransport() {
        let broken = StructuredWorkout(title: "Broken", steps: [
            WorkoutStep(kind: .work, target: .distance(-400), paceSPerKm: .infinity),
        ])
        let payload = ExecutionPrescriptionBuilder.build(
            planID: "plan",
            sessionID: "session",
            intent: intent(),
            legacy: legacyFields(),
            structuredWorkout: broken
        )
        #expect(payload.validationIssues.contains(.invalidStructuredStep))
    }
}

private extension ExecutionPrescriptionTests {
    func intent() -> SessionIntent {
        SessionIntent(
            id: "intent:quality:1",
            version: 1,
            weekIndex: 2,
            dayOffset: 3,
            discipline: .running,
            legacyRunType: .intervals,
            stimulus: .vo2,
            sessionClass: .quality,
            progressionLevel: 2,
            hardClass: .hardRun,
            targetHierarchy: RunningTargetHierarchy(
                primary: .intervalStructure,
                fallbacks: [.pace, .effort]
            ),
            workDose: RunningWorkDose(
                distanceM: 6_000,
                durationS: 2_100,
                paceSPerKm: 250,
                intervalPrescription: "4×400m @ 5K effort",
                strengthTargets: []
            ),
            recoveryDose: RunningRecoveryDose(distanceM: nil, durationS: 90, mode: .duration),
            successRange: RunningValueRange(lower: 245, upper: 260),
            expectedRecoveryCost: .high,
            validSubstitutionIDs: ["intent:fartlek:1"],
            minimumEvidenceToProgress: .init(minimumCompletedExposures: 2, minimumConfidence: .moderate),
            purpose: "Develop controlled speed without racing the workout.",
            ruleIDs: [.qualityDose, .hardDaySpacing],
            limitations: []
        )
    }

    func legacyFields() -> LegacyExecutionFields {
        LegacyExecutionFields(
            discipline: .running,
            runType: .intervals,
            targetDistanceM: 6_000,
            targetDurationS: 2_100,
            targetPaceSPerKm: 250,
            intervalPrescription: "4×400m @ 5K effort"
        )
    }

    func fallbackFields() -> LegacyExecutionFields {
        LegacyExecutionFields(
            discipline: .running,
            runType: .easy,
            targetDistanceM: 5_000,
            targetDurationS: 1_800,
            targetPaceSPerKm: 360,
            intervalPrescription: nil
        )
    }

    func record(primary: String) -> PlannedSessionIntentRecord {
        PlannedSessionIntentRecord(
            id: "intent:persisted:1",
            plannedSessionID: id(2),
            planID: id(1),
            seasonID: id(3),
            intentVersion: 1,
            weekIndex: 2,
            dayOffset: 3,
            stimulusRaw: RunningStimulus.threshold.rawValue,
            sessionClassRaw: RunningIntentSessionClass.quality.rawValue,
            progressionLevel: 1,
            hardClassRaw: RunningHardClass.hardRun.rawValue,
            primaryTargetRaw: primary,
            fallbackTargetRaws: [RunningTargetKind.effort.rawValue],
            workDistanceM: 8_000,
            workDurationS: 2_720,
            workPaceSPerKm: 340,
            intervalPrescription: "20 min controlled",
            strengthTargetsJSON: Data("[]".utf8),
            recoveryDistanceM: nil,
            recoveryDurationS: nil,
            recoveryModeRaw: nil,
            successLower: 330,
            successUpper: 350,
            recoveryCostRaw: RunningRecoveryCostBand.moderate.rawValue,
            validSubstitutionIDs: [],
            minimumCompletedExposures: 2,
            minimumConfidenceRaw: RunningEvidenceConfidence.moderate.rawValue,
            purpose: "Build controlled threshold endurance.",
            ruleIDRaws: [RunningRuleID.qualityDose.rawValue],
            limitationRaws: [],
            createdAt: RunningPlannerTestFixtures.startDate
        )
    }

    func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", value))!
    }
}
