import Foundation
import SwiftData
import Testing
@testable import Momentum

private final class RunningMigrationFixtureBundleToken: NSObject {}

@Suite(.serialized)
@MainActor
struct RunningSchemaMigrationSpikeTests {
    private enum InterruptedBackfill: Error { case beforeSave }

    private struct FixtureIDs {
        let profile: UUID
        let plan: UUID
        let session: UUID
        let workout: UUID
        let photo: UUID
        let athlete: UUID
        let note: UUID
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.locale = Locale(identifier: "en_US_POSIX")
        return value
    }

    @Test func latestSchemaRegistryContainsEveryProductionModelExactlyOnce() {
        let expected: [any PersistentModel.Type] = [
            UserProfile.self,
            Workout.self, WorkoutPhoto.self, GPSDetail.self, LocationSample.self, Split.self, HeartRateSample.self,
            StrengthSession.self, WorkoutExercise.self, SetEntry.self,
            Exercise.self,
            TrainingPlan.self, PlannedSession.self, PlannedExercise.self,
            PersonalRecord.self,
            SavedRoute.self,
            EarnedAward.self,
            AthleteModel.self, MemoryNote.self, FitnessSnapshot.self,
            ChatMessage.self,
            CoachingEvent.self,
            AppNotification.self,
            DailyCheckin.self,
            Meal.self, WaterEntry.self,
            RunningSeasonRecord.self,
            RunningEventRecord.self,
            PlanMetadataRecord.self,
            PlannedSessionIntentRecord.self,
            PlanDecisionRecord.self,
            PlanAthleteStateRecord.self,
        ]
        let actualIDs = PersistenceController.models.map { ObjectIdentifier($0) }
        let expectedIDs = expected.map { ObjectIdentifier($0) }

        #expect(actualIDs.count == expectedIDs.count)
        #expect(Set(actualIDs).count == actualIDs.count)
        #expect(Set(actualIDs) == Set(expectedIDs))
        #expect(!actualIDs.contains(ObjectIdentifier(SchemaV1.AppNotification.self)))
    }

    /// Release gate: unlike `additiveSidecarsMigrateARealV1StoreWithoutDamagingTrainingHistory`,
    /// this store was written by the committed build-36 binary, not today's model classes. It
    /// catches accidental changes to a V1 model shape that a freshly generated "V1" fixture masks.
    @Test func archivedBuild36StoreMigratesBackfillsAndReopensIdempotently() throws {
        let fixtureURL = try #require(
            Bundle(for: RunningMigrationFixtureBundleToken.self).url(
                forResource: "ArchivedRunningSchemaV1Build36",
                withExtension: "store"
            )
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("momentum-archived-v1-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("V1.store")
        try FileManager.default.copyItem(at: fixtureURL, to: storeURL)
        let schema = Schema(versionedSchema: SchemaV4.self)
        let configuration = ModelConfiguration(
            "ArchivedRunningSchemaV1",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        var container: ModelContainer? = try ModelContainer(
            for: schema,
            migrationPlan: MomentumMigrationPlan.self,
            configurations: [configuration]
        )
        try assertArchivedBuild36Graph(in: #require(container))

        do {
            _ = try RunningPlanBackfill.repair(
                in: #require(container),
                now: Date(timeIntervalSinceReferenceDate: 1_250),
                calendar: calendar,
                beforeSave: { throw InterruptedBackfill.beforeSave }
            )
            Issue.record("Expected the interrupted launch fixture to fail before save")
        } catch is InterruptedBackfill {
            // Expected: the pass must roll back every inserted sidecar.
        }
        try assertArchivedBuild36Graph(in: #require(container))
        container = nil

        container = try ModelContainer(
            for: schema,
            migrationPlan: MomentumMigrationPlan.self,
            configurations: [configuration]
        )
        try assertArchivedBuild36Graph(in: #require(container))

        let first = try RunningPlanBackfill.repair(
            in: #require(container),
            now: Date(timeIntervalSinceReferenceDate: 1_500),
            calendar: calendar
        )
        #expect(first.createdSeasons == 1)
        #expect(first.createdEvents == 1)
        #expect(first.createdMetadata == 1)
        #expect(first.createdIntents == 1)
        #expect(first.updatedSeasons == 0)
        #expect(first.updatedEvents == 0)
        #expect(first.updatedMetadata == 0)
        #expect(first.updatedIntents == 0)
        #expect(first.removedOrphans == 0)
        #expect(first.didSave)
        container = nil

        container = try ModelContainer(
            for: schema,
            migrationPlan: MomentumMigrationPlan.self,
            configurations: [configuration]
        )
        try assertArchivedBuild36Graph(in: #require(container), expectsBackfill: true)
        let second = try RunningPlanBackfill.repair(
            in: #require(container),
            now: Date(timeIntervalSinceReferenceDate: 2_000),
            calendar: calendar
        )
        #expect(second == RunningPlanBackfill.Report())
        container = nil

        let finalContainer = try ModelContainer(
            for: schema,
            migrationPlan: MomentumMigrationPlan.self,
            configurations: [configuration]
        )
        try assertArchivedBuild36Graph(in: finalContainer, expectsBackfill: true)
    }

    @Test func additiveSidecarsMigrateARealV1StoreWithoutDamagingTrainingHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("momentum-running-migration-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("V1.store")
        let ids = try writeV1Fixture(to: storeURL)

        let schema = Schema(versionedSchema: SchemaV4.self)
        let configuration = ModelConfiguration(
            "RunningMigrationSpike",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        var migrated: ModelContainer? = try ModelContainer(
            for: schema,
            migrationPlan: MomentumMigrationPlan.self,
            configurations: [configuration]
        )
        var context = try #require(migrated?.mainContext)

        let profile = try #require(try context.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(profile.id == ids.profile)
        #expect(profile.displayName == "Migration Runner")
        #expect(profile.plan?.id == ids.plan)
        #expect(profile.plan?.name == "Chicago 10K")
        #expect(profile.workouts.map(\.id) == [ids.workout])
        #expect(profile.athlete?.id == ids.athlete)
        #expect(profile.athlete?.notes.map(\.id) == [ids.note])

        let plan = try #require(try context.fetch(FetchDescriptor<TrainingPlan>()).first)
        let session = try #require(plan.sessions.first)
        #expect(session.id == ids.session)
        #expect(session.completedWorkout?.id == ids.workout)
        #expect(session.targetDistanceM == 10_000)

        let workout = try #require(try context.fetch(FetchDescriptor<Workout>()).first)
        #expect(workout.id == ids.workout)
        #expect(workout.plannedSession?.id == ids.session)
        #expect(workout.gps?.distanceM == 10_000)
        #expect(workout.gps?.samples.count == 2)
        #expect(workout.gps?.samples.sorted { $0.t < $1.t }.map(\.lat) == [41.881, 41.882])
        #expect(workout.photos.map(\.id) == [ids.photo])
        #expect(workout.photos.first?.data == Data([0x4d, 0x4f, 0x4d]))

        #expect(try context.fetchCount(FetchDescriptor<RunningSeasonRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RunningEventRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PlanMetadataRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PlannedSessionIntentRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)

        let seasonID = UUID()
        let requestID = UUID()
        context.insert(RunningSeasonRecord(
            id: seasonID,
            profileID: ids.profile,
            activePlanID: ids.plan,
            name: "  Chicago 10K  ",
            createdAt: Date(timeIntervalSinceReferenceDate: 700),
            updatedAt: Date(timeIntervalSinceReferenceDate: 800),
            statusRaw: RunningSeasonStatus.active.rawValue,
            primaryOutcomeRaw: RunningPrimaryOutcome.targetTime.rawValue,
            motivationRaws: [RunningMotivation.performance.rawValue,
                             RunningMotivation.health.rawValue,
                             RunningMotivation.performance.rawValue]
        ))
        context.insert(RunningEventRecord(
            id: UUID(),
            seasonID: seasonID,
            name: "Chicago 10K",
            date: Date(timeIntervalSinceReferenceDate: 900),
            distanceM: 10_000,
            durationS: 2_700,
            priorityRaw: RunningEventPriority.a.rawValue,
            surfaceRaw: RunningEventSurface.road.rawValue
        ))
        context.insert(PlanMetadataRecord(
            planID: ids.plan,
            seasonID: seasonID,
            requestID: requestID,
            plannerVersion: "spike-v2",
            rulesetID: "legacy-road-v1",
            policyIDRaw: "road5K10K",
            semanticDigest: "fixture-digest",
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000)
        ))
        context.insert(PlannedSessionIntentRecord(
            id: "week-0-day-2-easy",
            plannedSessionID: ids.session,
            planID: ids.plan,
            seasonID: seasonID,
            intentVersion: 1,
            weekIndex: 0,
            dayOffset: 2,
            stimulusRaw: RunningStimulus.aerobicEndurance.rawValue,
            sessionClassRaw: RunningIntentSessionClass.easy.rawValue,
            progressionLevel: 1,
            hardClassRaw: RunningHardClass.none.rawValue,
            primaryTargetRaw: RunningTargetKind.distance.rawValue,
            fallbackTargetRaws: [RunningTargetKind.duration.rawValue,
                                 RunningTargetKind.effort.rawValue],
            workDistanceM: 10_000,
            workDurationS: nil,
            workPaceSPerKm: 330,
            intervalPrescription: nil,
            strengthTargetsJSON: Data("[]".utf8),
            recoveryDistanceM: nil,
            recoveryDurationS: nil,
            recoveryModeRaw: nil,
            successLower: 9_500,
            successUpper: 10_500,
            recoveryCostRaw: RunningRecoveryCostBand.low.rawValue,
            validSubstitutionIDs: ["easy-duration"],
            minimumCompletedExposures: 2,
            minimumConfidenceRaw: RunningEvidenceConfidence.moderate.rawValue,
            purpose: "Build aerobic durability.",
            ruleIDRaws: ["schedule.frequency-cap", "dose.easy-pace"],
            limitationRaws: [RunningEvidenceLimitation.smallSample.rawValue],
            createdAt: Date(timeIntervalSinceReferenceDate: 1_100)
        ))
        context.insert(PlanDecisionRecord(
            id: UUID(),
            requestID: requestID,
            profileID: ids.profile,
            planID: ids.plan,
            seasonID: seasonID,
            decidedAt: Date(timeIntervalSinceReferenceDate: 1_200),
            triggerRaw: RunningPlanningTrigger.initialPlan.rawValue,
            statusRaw: RunningDecisionStatus.candidate.rawValue,
            plannerVersion: "spike-v2",
            rulesetID: "legacy-road-v1",
            policyIDRaw: "road5K10K",
            oldPlanDigest: nil,
            newPlanDigest: "fixture-digest",
            diffJSON: Data("{\"version\":1}".utf8),
            appliedRuleIDRaws: ["dose.easy-pace"],
            hardConstraintRaws: ["frequencyCap"],
            relaxedPreferenceRaws: [],
            evidenceConfidenceRaws: [RunningEvidenceConfidence.moderate.rawValue],
            limitationRaws: [RunningEvidenceLimitation.smallSample.rawValue],
            headline: "Built around your 10K goal",
            detail: "The first week protects consistency before adding demand.",
            normalizedInputJSON: Data("{\"version\":1}".utf8)
        ))
        try context.save()

        // Release every context/container reference before proving the migrated store reopens.
        migrated = nil
        let reopened = try ModelContainer(
            for: schema,
            migrationPlan: MomentumMigrationPlan.self,
            configurations: [configuration]
        )
        context = ModelContext(reopened)

        let season = try #require(try context.fetch(FetchDescriptor<RunningSeasonRecord>()).first)
        #expect(season.name == "Chicago 10K")
        #expect(season.motivationRaws == [RunningMotivation.health.rawValue,
                                        RunningMotivation.performance.rawValue])
        #expect(try context.fetchCount(FetchDescriptor<RunningEventRecord>()) == 1)
        #expect(try context.fetch(FetchDescriptor<PlanMetadataRecord>()).first?.id == ids.plan)
        #expect(try context.fetch(FetchDescriptor<PlannedSessionIntentRecord>()).first?.plannedSessionID == ids.session)
        #expect(try context.fetch(FetchDescriptor<PlanDecisionRecord>()).first?.requestID == requestID)

        // V1 rows and their completed-workout link still survive after V2 has written its own rows.
        let reopenedSession = try #require(try context.fetch(FetchDescriptor<PlannedSession>()).first)
        #expect(reopenedSession.completedWorkout?.id == ids.workout)
        #expect(try context.fetch(FetchDescriptor<LocationSample>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<WorkoutPhoto>()).first?.data == Data([0x4d, 0x4f, 0x4d]))
    }

    private func assertArchivedBuild36Graph(in container: ModelContainer,
                                            expectsBackfill: Bool = false) throws {
        let context = ModelContext(container)
        let profileID = archivedID(1)
        let planID = archivedID(2)
        let sessionID = archivedID(3)
        let workoutID = archivedID(4)

        #expect(try context.fetchCount(FetchDescriptor<UserProfile>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<TrainingPlan>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PlannedSession>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Workout>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<GPSDetail>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<LocationSample>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<WorkoutPhoto>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<AthleteModel>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<MemoryNote>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<AppNotification>()) == 1)

        let profile = try #require(try context.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(profile.id == profileID)
        #expect(profile.displayName == "Archived Build 36 Runner")
        #expect(profile.goal == .raceDistance)
        #expect(profile.raceDistanceM == 10_000)
        #expect(profile.goalFinishTimeS == 2_700)
        #expect(profile.plan?.id == planID)
        #expect(profile.workouts.map(\.id) == [workoutID])
        #expect(profile.athlete?.id == archivedID(6))
        #expect(profile.athlete?.notes.map(\.id) == [archivedID(7)])

        let plan = try #require(profile.plan)
        #expect(plan.name == "Chicago 10K")
        let session = try #require(plan.sessions.first)
        #expect(session.id == sessionID)
        #expect(session.status == .completed)
        #expect(session.completedWorkout?.id == workoutID)

        let workout = try #require(try context.fetch(FetchDescriptor<Workout>()).first)
        #expect(workout.id == workoutID)
        #expect(workout.plannedSession?.id == sessionID)
        #expect(workout.gps?.distanceM == 10_000)
        #expect(workout.gps?.samples.count == 2)
        #expect(workout.gps?.samples.sorted { $0.t < $1.t }.map(\.lat) == [41.881, 41.882])
        #expect(workout.photos.map(\.id) == [archivedID(5)])
        #expect(workout.photos.first?.data == Data([0x4d, 0x4f, 0x4d]))

        let notification = try #require(try context.fetch(FetchDescriptor<AppNotification>()).first)
        #expect(notification.id == archivedID(8))
        #expect(notification.dedupeToken == "archived-build-36")
        #expect(notification.targetPostID == nil)
        #expect(notification.targetHandle == nil)

        let expectedCount = expectsBackfill ? 1 : 0
        #expect(try context.fetchCount(FetchDescriptor<RunningSeasonRecord>()) == expectedCount)
        #expect(try context.fetchCount(FetchDescriptor<RunningEventRecord>()) == expectedCount)
        #expect(try context.fetchCount(FetchDescriptor<PlanMetadataRecord>()) == expectedCount)
        #expect(try context.fetchCount(FetchDescriptor<PlannedSessionIntentRecord>()) == expectedCount)
        #expect(try context.fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)

        guard expectsBackfill else { return }
        let season = try #require(try context.fetch(FetchDescriptor<RunningSeasonRecord>()).first)
        #expect(season.id == profileID)
        #expect(season.profileID == profileID)
        #expect(season.activePlanID == planID)
        #expect(season.name == "Chicago 10K")
        #expect(season.backfillVersion == RunningPlanBackfill.currentVersion)

        let event = try #require(try context.fetch(FetchDescriptor<RunningEventRecord>()).first)
        #expect(event.id == profileID)
        #expect(event.seasonID == profileID)
        #expect(event.distanceM == 10_000)
        #expect(event.durationS == 2_700)

        let metadata = try #require(try context.fetch(FetchDescriptor<PlanMetadataRecord>()).first)
        #expect(metadata.id == planID)
        #expect(metadata.planID == planID)
        #expect(metadata.seasonID == profileID)
        #expect(metadata.isLegacyBackfill)
        #expect(metadata.semanticDigest.hasPrefix("v1:sha256:"))

        let intent = try #require(try context.fetch(FetchDescriptor<PlannedSessionIntentRecord>()).first)
        #expect(intent.plannedSessionID == sessionID)
        #expect(intent.planID == planID)
        #expect(intent.seasonID == profileID)
        #expect(intent.workDistanceM == 10_000)
    }

    private func archivedID(_ value: Int) -> UUID {
        UUID(uuidString: "B0360000-0000-0000-0000-\(String(format: "%012x", value))")!
    }

    private func writeV1Fixture(to storeURL: URL) throws -> FixtureIDs {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(
            "RunningMigrationSpike",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let profile = UserProfile()
        profile.id = UUID()
        profile.displayName = "Migration Runner"
        profile.goal = .raceDistance
        profile.raceDistanceM = 10_000
        profile.goalFinishTimeS = 2_700
        profile.weeklyRunVolumeM = 24_000

        let plan = TrainingPlan()
        plan.id = UUID()
        plan.name = "Chicago 10K"
        plan.goal = .raceDistance
        plan.raceDate = Date(timeIntervalSinceReferenceDate: 900)

        let session = PlannedSession()
        session.id = UUID()
        session.date = Date(timeIntervalSinceReferenceDate: 500)
        session.discipline = .running
        session.runType = .easy
        session.targetDistanceM = 10_000
        session.status = .completed

        let workout = Workout()
        workout.id = UUID()
        workout.type = .run
        workout.startedAt = Date(timeIntervalSinceReferenceDate: 500)
        workout.durationS = 3_300
        workout.elapsedS = 3_330
        workout.title = "Lakefront easy run"

        let gps = GPSDetail()
        gps.distanceM = 10_000
        gps.avgPaceSPerKm = 330
        let first = LocationSample()
        first.t = Date(timeIntervalSinceReferenceDate: 500)
        first.lat = 41.881
        first.lon = -87.623
        first.accuracyM = 4
        first.speedMS = 3.03
        let second = LocationSample()
        second.t = Date(timeIntervalSinceReferenceDate: 501)
        second.lat = 41.882
        second.lon = -87.622
        second.accuracyM = 5
        second.speedMS = 3.01
        gps.samples = [first, second]
        workout.gps = gps

        let photo = WorkoutPhoto(order: 0, data: Data([0x4d, 0x4f, 0x4d]))
        photo.id = UUID()
        workout.photos = [photo]

        let athlete = AthleteModel()
        athlete.id = UUID()
        athlete.planAdherence28d = 0.92
        let note = MemoryNote()
        note.id = UUID()
        note.category = MemoryCategory.identity.rawValue
        note.text = "You build confidence through steady weeks."
        note.source = MemorySource.user.rawValue
        athlete.notes = [note]

        plan.sessions = [session]
        profile.plan = plan
        profile.workouts = [workout]
        profile.athlete = athlete
        workout.plannedSession = session
        session.completedWorkout = workout
        context.insert(profile)
        try context.save()

        return FixtureIDs(
            profile: profile.id,
            plan: plan.id,
            session: session.id,
            workout: workout.id,
            photo: photo.id,
            athlete: athlete.id,
            note: note.id
        )
    }
}
