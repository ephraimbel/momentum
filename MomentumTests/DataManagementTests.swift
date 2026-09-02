import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Export + delete (PRD §13.3): a full JSON snapshot, and a wipe that removes every personal record
/// while preserving the bundled exercise catalog.
@MainActor
struct DataManagementTests {

    private struct PlannerSidecarIDs {
        let season: UUID
        let event: UUID
        let request: UUID
        let intent: String
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func exportsProfileAndWorkoutsAsJSON() throws {
        let container = try makeContainer()   // retain it — a temporary would dealloc the context
        let ctx = container.mainContext
        let profile = UserProfile(); profile.displayName = "Sam"; ctx.insert(profile)
        let plan = TrainingPlan(); plan.name = "Spring 10K"
        let session = PlannedSession(); plan.sessions = [session]; profile.plan = plan
        let run = Workout(); run.type = .run; run.startedAt = Date(); run.durationS = 1800
        let g = GPSDetail(); g.distanceM = 5000; run.gps = g
        ctx.insert(run)
        let sidecarIDs = insertPlannerSidecars(in: ctx, profileID: profile.id,
                                               planID: plan.id, sessionID: session.id)
        try ctx.save()

        let data = DataManager.exportJSON(in: ctx, now: Date(timeIntervalSinceReferenceDate: 0))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DataManager.Snapshot.self, from: data)

        #expect(snapshot.app == "momentum")
        #expect(snapshot.schemaVersion == 2)
        #expect(snapshot.profile?.displayName == "Sam")
        #expect(snapshot.workouts.count == 1)
        #expect(snapshot.workouts.first?.distanceM == 5000)
        #expect(snapshot.runningSeasons.map(\.id) == [sidecarIDs.season])
        #expect(snapshot.runningEvents.map(\.id) == [sidecarIDs.event])
        #expect(snapshot.planMetadata.first?.planID == plan.id)
        #expect(snapshot.plannedSessionIntents.map(\.id) == [sidecarIDs.intent])
        #expect(snapshot.planDecisions.map(\.requestID) == [sidecarIDs.request])
        #expect(snapshot.planDecisions.first?.normalizedInputJSON == Data("{\"volumeM\":24000}".utf8))
    }

    @Test func deleteWipesUserDataButKeepsTheCatalog() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile(); ctx.insert(profile)
        let workout = Workout(); ctx.insert(workout)
        let plan = TrainingPlan(); let session = PlannedSession(); plan.sessions = [session]; ctx.insert(plan)
        _ = insertPlannerSidecars(in: ctx, profileID: profile.id,
                                  planID: plan.id, sessionID: session.id)
        let exercise = Exercise(name: "Bench", primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        ctx.insert(exercise)
        try ctx.save()

        DataManager.deleteAllUserData(in: ctx)

        #expect((try ctx.fetch(FetchDescriptor<UserProfile>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<Workout>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<TrainingPlan>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<RunningSeasonRecord>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<RunningEventRecord>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<PlanMetadataRecord>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<PlannedSessionIntentRecord>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<PlanDecisionRecord>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<Exercise>())).count == 1)   // catalog preserved
    }

    @Test func backgroundDeleteAlsoWipesRunningPlannerAuditRows() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        _ = insertPlannerSidecars(in: ctx, profileID: UUID(), planID: UUID(), sessionID: UUID())
        try ctx.save()

        await DataManager.deleteAllUserData(container: container)

        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<RunningSeasonRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<RunningEventRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlanMetadataRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlannedSessionIntentRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)
    }

    @discardableResult
    private func insertPlannerSidecars(in context: ModelContext,
                                       profileID: UUID,
                                       planID: UUID,
                                       sessionID: UUID) -> PlannerSidecarIDs {
        let seasonID = UUID()
        let eventID = UUID()
        let requestID = UUID()
        let intentID = "fixture-easy-run"
        context.insert(RunningSeasonRecord(
            id: seasonID,
            profileID: profileID,
            activePlanID: planID,
            name: "Spring 10K",
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            statusRaw: RunningSeasonStatus.active.rawValue,
            primaryOutcomeRaw: RunningPrimaryOutcome.targetTime.rawValue,
            motivationRaws: [RunningMotivation.performance.rawValue]
        ))
        context.insert(RunningEventRecord(
            id: eventID,
            seasonID: seasonID,
            name: "Spring 10K",
            date: Date(timeIntervalSinceReferenceDate: 30),
            distanceM: 10_000,
            durationS: 2_700,
            priorityRaw: RunningEventPriority.a.rawValue,
            surfaceRaw: RunningEventSurface.road.rawValue
        ))
        context.insert(PlanMetadataRecord(
            planID: planID,
            seasonID: seasonID,
            requestID: requestID,
            plannerVersion: "test-v1",
            rulesetID: "legacy-road-v1",
            policyIDRaw: "road5K10K",
            semanticDigest: "digest",
            createdAt: Date(timeIntervalSinceReferenceDate: 40)
        ))
        context.insert(PlannedSessionIntentRecord(
            id: intentID,
            plannedSessionID: sessionID,
            planID: planID,
            seasonID: seasonID,
            intentVersion: 1,
            weekIndex: 0,
            dayOffset: 1,
            stimulusRaw: RunningStimulus.aerobicEndurance.rawValue,
            sessionClassRaw: RunningIntentSessionClass.easy.rawValue,
            progressionLevel: 1,
            hardClassRaw: RunningHardClass.none.rawValue,
            primaryTargetRaw: RunningTargetKind.distance.rawValue,
            fallbackTargetRaws: [RunningTargetKind.duration.rawValue],
            workDistanceM: 5_000,
            workDurationS: nil,
            workPaceSPerKm: 360,
            intervalPrescription: nil,
            strengthTargetsJSON: Data("[]".utf8),
            recoveryDistanceM: nil,
            recoveryDurationS: nil,
            recoveryModeRaw: nil,
            successLower: 4_750,
            successUpper: 5_250,
            recoveryCostRaw: RunningRecoveryCostBand.low.rawValue,
            validSubstitutionIDs: [],
            minimumCompletedExposures: 2,
            minimumConfidenceRaw: RunningEvidenceConfidence.moderate.rawValue,
            purpose: "Build consistency.",
            ruleIDRaws: ["dose.easy-pace"],
            limitationRaws: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 50)
        ))
        context.insert(PlanDecisionRecord(
            id: UUID(),
            requestID: requestID,
            profileID: profileID,
            planID: planID,
            seasonID: seasonID,
            decidedAt: Date(timeIntervalSinceReferenceDate: 60),
            triggerRaw: RunningPlanningTrigger.initialPlan.rawValue,
            statusRaw: RunningDecisionStatus.candidate.rawValue,
            plannerVersion: "test-v1",
            rulesetID: "legacy-road-v1",
            policyIDRaw: "road5K10K",
            oldPlanDigest: nil,
            newPlanDigest: "digest",
            diffJSON: Data("{\"added\":1}".utf8),
            appliedRuleIDRaws: ["dose.easy-pace"],
            hardConstraintRaws: ["frequencyCap"],
            relaxedPreferenceRaws: [],
            evidenceConfidenceRaws: [RunningEvidenceConfidence.moderate.rawValue],
            limitationRaws: [],
            headline: "Built around your 10K",
            detail: "A consistent first week.",
            normalizedInputJSON: Data("{\"volumeM\":24000}".utf8)
        ))
        return PlannerSidecarIDs(season: seasonID, event: eventID,
                                 request: requestID, intent: intentID)
    }
}
