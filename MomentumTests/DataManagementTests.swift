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
        AdaptivePlanService.initialize(plan, profileID: profile.id, now: run.startedAt, in: ctx)
        var feedback = WorkoutRecoveryDraft(); feedback.recovery = 2; feedback.pain = false
        feedback.persist(for: run)
        let sidecarIDs = insertPlannerSidecars(in: ctx, profileID: profile.id,
                                               planID: plan.id, sessionID: session.id)
        try ctx.save()

        let data = DataManager.exportJSON(in: ctx, now: Date(timeIntervalSinceReferenceDate: 0))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DataManager.Snapshot.self, from: data)

        #expect(snapshot.app == "momentum")
        #expect(snapshot.schemaVersion == 3)
        #expect(snapshot.adaptivePlans?.first?.planID == plan.id)
        #expect(snapshot.workoutFeedback?.first?.workoutID == run.id)
        #expect(snapshot.workoutFeedback?.first?.pain == false)
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
        ctx.insert(SavedRoute(postID: UUID(), title: "Saved example", authorName: "Runner",
                              authorHandle: nil, city: nil, km: 5,
                              pts: [[40, -74], [40.01, -74.01]], mapStyle: .standard))
        try ctx.save()

        DataManager.deleteAllUserData(in: ctx)

        #expect(try ctx.fetchCount(FetchDescriptor<SavedRoute>()) == 0)
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
        ctx.insert(SavedRoute(postID: UUID(), title: "Saved example", authorName: "Runner",
                              authorHandle: nil, city: nil, km: 5,
                              pts: [[40, -74], [40.01, -74.01]], mapStyle: .standard))
        try ctx.save()

        try await DataManager.deleteAllUserData(container: container)

        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<SavedRoute>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<RunningSeasonRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<RunningEventRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlanMetadataRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlannedSessionIntentRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)
    }

    @Test(arguments: [true, false])
    func backgroundDeleteDisconnectsOwnedGraphBeforeDeletingChildren(inMemory: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(PersistenceController.models)
        let configuration = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: directory.appendingPathComponent("delete.store"))
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let profile = UserProfile()
        context.insert(profile)
        let exercise = Exercise(name: "Bench", primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        context.insert(exercise)
        // Cross both chunk boundaries. The old test never attached a plan to a profile;
        // production crashed when the final profile cascade revisited its deleted plan.
        for index in 0..<35 {
            let plan = TrainingPlan()
            let session = PlannedSession()
            let target = PlannedExercise(); target.exercise = exercise
            session.strengthTargets = [target]
            plan.sessions = [session]
            context.insert(plan)
            if index == 0 { profile.plan = plan }
            if index < 9 {
                let workout = Workout()
                workout.gps = GPSDetail()
                workout.plannedSession = session
                session.completedWorkout = workout
                profile.workouts.append(workout)
                profile.prs.append(PersonalRecord(type: .fastest5k, value: 1500, workout: workout))
            }
        }
        profile.athlete = AthleteModel()
        try context.save()

        try await DataManager.deleteAllUserData(container: container)
        // A repeat after an interrupted/retried request must terminate cleanly too.
        try await DataManager.deleteAllUserData(container: container)

        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<UserProfile>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<TrainingPlan>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlannedSession>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlannedExercise>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<Workout>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<GPSDetail>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PersonalRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<AthleteModel>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<Exercise>()) == 1)
    }

    @Test func startupRepairClearsMissingPlanButPreservesOtherPlans() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(PersistenceController.models)
        let config = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("repair.store"))
        let container = try ModelContainer(for: schema, configurations: [config])
        let write = ModelContext(container)
        let broken = UserProfile(); broken.displayName = "Interrupted erase"
        let missing = TrainingPlan(); missing.sessions = [PlannedSession()]
        broken.plan = missing
        write.insert(broken)
        let healthy = UserProfile(); healthy.displayName = "Keep"
        let intact = TrainingPlan(); intact.name = "Keep this plan"; intact.sessions = [PlannedSession()]
        healthy.plan = intact
        write.insert(healthy)
        try write.save()
        // Reproduce the old first chunk, then use a fresh context like a relaunch.
        write.delete(missing)
        try write.save()
        let reopened = ModelContext(container)
        try DataManager.repairDanglingProfileReferences(in: reopened)
        try DataManager.repairDanglingProfileReferences(in: reopened)
        let profiles = try reopened.fetch(FetchDescriptor<UserProfile>())
        #expect(profiles.first { $0.displayName == "Interrupted erase" }?.plan == nil)
        let remaining = try #require(profiles.first { $0.displayName == "Keep" }?.plan)
        #expect(remaining.name == "Keep this plan")
        #expect(remaining.sessions.count == 1)
        #expect(try reopened.fetchCount(FetchDescriptor<UserProfile>()) == 2)
        #expect(try reopened.fetchCount(FetchDescriptor<TrainingPlan>()) == 1)
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
