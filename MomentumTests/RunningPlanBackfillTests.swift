import Foundation
import SwiftData
import Testing
@testable import Momentum

@Suite(.serialized)
@MainActor
struct RunningPlanBackfillTests {
    private enum InjectedFailure: Error { case beforeSave }

    private struct FixtureIDs {
        let profile: UUID
        let plan: UUID
        let runSession: UUID
        let strengthSession: UUID
        let workout: UUID
    }

    private struct SidecarSnapshot: Equatable {
        let seasonID: UUID
        let seasonName: String
        let seasonUpdatedAt: Date
        let eventID: UUID
        let eventDate: Date
        let metadataDigest: String
        let intentIDs: [String]
        let intentPayloads: [Data]
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.locale = Locale(identifier: "en_US_POSIX")
        return value
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    @Test func legacyPlanBackfillsExactlyOnceWithoutTouchingTrainingHistory() throws {
        let container = try makeContainer()
        let ids = try seedRacePlan(in: container)
        let now = Date(timeIntervalSinceReferenceDate: 900_000)

        let first = try RunningPlanBackfill.repair(
            in: container,
            now: now,
            calendar: calendar
        )

        #expect(first.createdSeasons == 1)
        #expect(first.createdEvents == 1)
        #expect(first.createdMetadata == 1)
        #expect(first.createdIntents == 2)
        #expect(first.didSave)

        var read = ModelContext(container)
        let profile = try #require(try read.fetch(FetchDescriptor<UserProfile>()).first)
        let plan = try #require(profile.plan)
        #expect(profile.id == ids.profile)
        #expect(plan.id == ids.plan)
        #expect(plan.name == "  Chicago Marathon  ")
        #expect(plan.goal == .raceDistance)
        #expect(plan.sessions.count == 2)
        let completed = try #require(plan.sessions.first { $0.id == ids.runSession })
        #expect(completed.status == .completed)
        #expect(completed.completedWorkout?.id == ids.workout)
        #expect(completed.completedWorkout?.plannedSession?.id == ids.runSession)

        let season = try #require(try read.fetch(FetchDescriptor<RunningSeasonRecord>()).first)
        #expect(season.id == ids.profile)
        #expect(season.activePlanID == ids.plan)
        #expect(season.name == "Chicago Marathon")
        #expect(season.statusRaw == RunningSeasonStatus.active.rawValue)
        #expect(season.primaryOutcomeRaw == RunningPrimaryOutcome.targetTime.rawValue)
        #expect(season.backfillVersion == RunningPlanBackfill.currentVersion)

        let event = try #require(try read.fetch(FetchDescriptor<RunningEventRecord>()).first)
        #expect(event.id == season.id)
        #expect(event.seasonID == season.id)
        #expect(event.distanceM == RaceDistance.marathon.meters)
        #expect(event.durationS == 10_800)

        let planMetadata = try #require(try read.fetch(FetchDescriptor<PlanMetadataRecord>()).first)
        #expect(planMetadata.id == ids.plan)
        #expect(planMetadata.seasonID == season.id)
        #expect(planMetadata.requestID == nil)
        #expect(planMetadata.plannerVersion == LegacyPlanReplay.currentPlannerVersion)
        #expect(planMetadata.rulesetID == PlanningRequest.legacyRulesetID)
        #expect(planMetadata.policyIDRaw == RunningPolicyID.legacyRoadV1.rawValue)
        #expect(planMetadata.semanticDigest.hasPrefix("v1:sha256:"))
        #expect(planMetadata.isLegacyBackfill)

        let intents = try read.fetch(FetchDescriptor<PlannedSessionIntentRecord>())
        #expect(intents.count == 2)
        let runIntent = try #require(intents.first { $0.plannedSessionID == ids.runSession })
        #expect(runIntent.stimulusRaw == RunningStimulus.aerobicEndurance.rawValue)
        #expect(runIntent.primaryTargetRaw == RunningTargetKind.distance.rawValue)
        #expect(runIntent.workDistanceM == 8_000)
        let strengthIntent = try #require(intents.first { $0.plannedSessionID == ids.strengthSession })
        #expect(strengthIntent.sessionClassRaw == RunningIntentSessionClass.strength.rawValue)
        #expect(strengthIntent.hardClassRaw == RunningHardClass.hardLowerBodyStrength.rawValue)
        let strengthTargets = try JSONDecoder().decode(
            [RunningStrengthTarget].self,
            from: strengthIntent.strengthTargetsJSON
        )
        #expect(strengthTargets.map(\RunningStrengthTarget.exerciseName) == ["Split Squat"])
        #expect(strengthTargets.first?.targetSets == 3)
        #expect(try read.fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)

        let initialSnapshot = try snapshot(in: read)
        read = ModelContext(container)
        let second = try RunningPlanBackfill.repair(
            in: container,
            now: now.addingTimeInterval(86_400),
            calendar: calendar
        )
        #expect(second == RunningPlanBackfill.Report())
        #expect(try snapshot(in: ModelContext(container)) == initialSnapshot)
    }

    @Test func partialBackfillResumesWithoutDuplicateSeasonOrEvent() throws {
        let container = try makeContainer()
        let ids = try seedRacePlan(in: container)
        let partial = ModelContext(container)
        partial.autosaveEnabled = false
        partial.insert(RunningSeasonRecord(
            id: ids.profile,
            profileID: ids.profile,
            activePlanID: ids.plan,
            name: "Chicago Marathon",
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 800_000),
            statusRaw: RunningSeasonStatus.active.rawValue,
            primaryOutcomeRaw: RunningPrimaryOutcome.targetTime.rawValue,
            motivationRaws: [RunningMotivation.performance.rawValue],
            backfillVersion: RunningPlanBackfill.currentVersion
        ))
        try partial.save()

        let report = try RunningPlanBackfill.repair(
            in: container,
            now: Date(timeIntervalSinceReferenceDate: 900_000),
            calendar: calendar
        )
        #expect(report.createdSeasons == 0)
        #expect(report.createdEvents == 1)
        #expect(report.createdMetadata == 1)
        #expect(report.createdIntents == 2)

        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<RunningSeasonRecord>()) == 1)
        #expect(try read.fetchCount(FetchDescriptor<RunningEventRecord>()) == 1)
        #expect(try read.fetchCount(FetchDescriptor<PlanMetadataRecord>()) == 1)
        #expect(try read.fetchCount(FetchDescriptor<PlannedSessionIntentRecord>()) == 2)

        let second = try RunningPlanBackfill.repair(in: container, calendar: calendar)
        #expect(!second.didSave)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<RunningEventRecord>()) == 1)
    }

    @Test func failedPassRollsBackEverySidecarAndLeavesTheLegacyGraphLive() throws {
        let container = try makeContainer()
        let ids = try seedRacePlan(in: container)

        do {
            _ = try RunningPlanBackfill.repair(
                in: container,
                calendar: calendar,
                beforeSave: { throw InjectedFailure.beforeSave }
            )
            Issue.record("Expected the injected failure")
        } catch is InjectedFailure {
            // Expected.
        }

        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<RunningSeasonRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<RunningEventRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlanMetadataRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlannedSessionIntentRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)
        let profile = try #require(try read.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(profile.plan?.id == ids.plan)
        #expect(profile.plan?.sessions.count == 2)
        #expect(profile.plan?.sessions.first(where: { $0.id == ids.runSession })?.completedWorkout?.id == ids.workout)

        let retry = try RunningPlanBackfill.repair(in: container, calendar: calendar)
        #expect(retry.didSave)
        #expect(retry.createdSeasons == 1)
    }

    @Test func orphanSweepKeepsValidSidecarsAndRetainedDecisionHistory() throws {
        let container = try makeContainer()
        let ids = try seedRacePlan(in: container)
        _ = try RunningPlanBackfill.repair(in: container, calendar: calendar)

        let write = ModelContext(container)
        write.autosaveEnabled = false
        let orphanSeasonID = UUID()
        let missingProfileID = UUID()
        let missingPlanID = UUID()
        let missingSessionID = UUID()
        let requestID = UUID()
        write.insert(RunningSeasonRecord(
            id: orphanSeasonID,
            profileID: missingProfileID,
            activePlanID: missingPlanID,
            name: "Orphan",
            createdAt: Date(),
            updatedAt: Date(),
            statusRaw: RunningSeasonStatus.active.rawValue,
            primaryOutcomeRaw: RunningPrimaryOutcome.buildBase.rawValue,
            motivationRaws: [],
            backfillVersion: 1
        ))
        write.insert(RunningEventRecord(
            id: UUID(),
            seasonID: orphanSeasonID,
            name: "Orphan Race",
            date: Date(),
            distanceM: 5_000,
            durationS: nil,
            priorityRaw: RunningEventPriority.a.rawValue,
            surfaceRaw: RunningEventSurface.road.rawValue
        ))
        write.insert(PlanMetadataRecord(
            planID: missingPlanID,
            seasonID: orphanSeasonID,
            requestID: nil,
            plannerVersion: "old",
            rulesetID: "old",
            policyIDRaw: nil,
            semanticDigest: "old",
            createdAt: Date(),
            isLegacyBackfill: true
        ))
        write.insert(emptyIntent(
            id: "orphan-intent",
            sessionID: missingSessionID,
            planID: missingPlanID,
            seasonID: orphanSeasonID
        ))
        write.insert(PlanDecisionRecord(
            id: UUID(),
            requestID: requestID,
            profileID: missingProfileID,
            planID: missingPlanID,
            seasonID: orphanSeasonID,
            decidedAt: Date(),
            triggerRaw: RunningPlanningTrigger.athleteAdjustment.rawValue,
            statusRaw: RunningDecisionStatus.candidate.rawValue,
            plannerVersion: "retained",
            rulesetID: "retained",
            policyIDRaw: nil,
            oldPlanDigest: nil,
            newPlanDigest: nil,
            diffJSON: Data(),
            appliedRuleIDRaws: [],
            hardConstraintRaws: [],
            relaxedPreferenceRaws: [],
            evidenceConfidenceRaws: [],
            limitationRaws: [],
            headline: "Retain me",
            detail: "Audit history outlives a replaceable plan.",
            normalizedInputJSON: Data()
        ))
        try write.save()

        let report = try RunningPlanBackfill.repair(in: container, calendar: calendar)
        #expect(report.removedOrphans == 4)

        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<RunningSeasonRecord>()) == 1)
        #expect(try read.fetchCount(FetchDescriptor<RunningEventRecord>()) == 1)
        #expect(try read.fetchCount(FetchDescriptor<PlanMetadataRecord>()) == 1)
        #expect(try read.fetchCount(FetchDescriptor<PlannedSessionIntentRecord>()) == 2)
        let decision = try #require(try read.fetch(FetchDescriptor<PlanDecisionRecord>()).first)
        #expect(decision.requestID == requestID)
        #expect(decision.headline == "Retain me")
        #expect(try read.fetch(FetchDescriptor<PlanMetadataRecord>()).first?.planID == ids.plan)
    }

    @Test func selfCoachedPlanGetsCompatibilityRowsButNoCoachingRewrite() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let profile = UserProfile()
        profile.goal = .stayConsistent
        let plan = TrainingPlan()
        plan.name = "My own week"
        plan.isSelfCoached = true
        plan.p5kSPerKm = 312
        let session = PlannedSession()
        session.date = Date(timeIntervalSinceReferenceDate: 700_000)
        session.discipline = .running
        session.runType = .tempo
        session.targetDistanceM = 7_000
        session.targetPaceSPerKm = 305
        plan.sessions = [session]
        profile.plan = plan
        context.insert(profile)
        try context.save()

        _ = try RunningPlanBackfill.repair(in: container, calendar: calendar)

        let read = ModelContext(container)
        let reopened = try #require(try read.fetch(FetchDescriptor<UserProfile>()).first?.plan)
        #expect(reopened.isSelfCoached)
        #expect(reopened.name == "My own week")
        #expect(reopened.p5kSPerKm == 312)
        #expect(reopened.sessions.first?.runType == .tempo)
        #expect(reopened.sessions.first?.targetDistanceM == 7_000)
        #expect(reopened.sessions.first?.targetPaceSPerKm == 305)
        let metadata = try #require(try read.fetch(FetchDescriptor<PlanMetadataRecord>()).first)
        #expect(metadata.policyIDRaw == nil)
        let intent = try #require(try read.fetch(FetchDescriptor<PlannedSessionIntentRecord>()).first)
        #expect(intent.ruleIDRaws == [RunningRuleID.selfCoachedBoundary.rawValue])
        #expect(intent.purpose.contains("will not rewrite"))
        #expect(try read.fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)
    }

    private func seedRacePlan(in container: ModelContainer) throws -> FixtureIDs {
        let context = container.mainContext
        let anchor = Date(timeIntervalSinceReferenceDate: 800_000)
        let profile = UserProfile()
        profile.id = UUID()
        profile.goal = .raceDistance
        profile.reason = "compete"
        profile.experience[Discipline.running.rawValue] = ExperienceLevel.experienced.rawValue
        profile.raceDate = calendar.date(byAdding: .day, value: 84, to: anchor)
        profile.raceDistanceM = RaceDistance.marathon.meters
        profile.goalFinishTimeS = 10_800

        let plan = TrainingPlan()
        plan.id = UUID()
        plan.name = "  Chicago Marathon  "
        plan.goal = .raceDistance
        plan.raceDate = profile.raceDate
        plan.createdAt = anchor
        plan.blockStart = anchor
        plan.weekPhases = [PlanPhase.base.rawValue, PlanPhase.build.rawValue]
        plan.p5kSPerKm = 295
        plan.goalRacePaceSPerKm = 256

        let run = PlannedSession()
        run.id = UUID()
        run.date = calendar.date(byAdding: .day, value: 2, to: anchor)!
        run.discipline = .running
        run.runType = .easy
        run.targetDistanceM = 8_000
        run.targetPaceSPerKm = 335
        run.status = .completed

        let workout = Workout()
        workout.id = UUID()
        workout.type = .run
        workout.startedAt = run.date
        workout.durationS = 2_680
        workout.plannedSession = run
        run.completedWorkout = workout
        profile.workouts = [workout]

        let exercise = Exercise(
            name: "Split Squat",
            primaryMuscles: [.quads, .glutes],
            equipment: .dumbbell,
            category: .compound
        )
        let target = PlannedExercise()
        target.order = 0
        target.exercise = exercise
        target.targetSets = 3
        target.targetRepLow = 8
        target.targetRepHigh = 10
        target.targetRPE = 7
        let strength = PlannedSession()
        strength.id = UUID()
        strength.date = calendar.date(byAdding: .day, value: 9, to: anchor)!
        strength.discipline = .strength
        strength.strengthLabel = "Lower"
        strength.strengthTargets = [target]

        plan.sessions = [run, strength]
        profile.plan = plan
        context.insert(profile)
        try context.save()
        return FixtureIDs(
            profile: profile.id,
            plan: plan.id,
            runSession: run.id,
            strengthSession: strength.id,
            workout: workout.id
        )
    }

    private func snapshot(in context: ModelContext) throws -> SidecarSnapshot {
        let season = try #require(try context.fetch(FetchDescriptor<RunningSeasonRecord>()).first)
        let event = try #require(try context.fetch(FetchDescriptor<RunningEventRecord>()).first)
        let metadata = try #require(try context.fetch(FetchDescriptor<PlanMetadataRecord>()).first)
        let intents = try context.fetch(FetchDescriptor<PlannedSessionIntentRecord>()).sorted { $0.id < $1.id }
        return SidecarSnapshot(
            seasonID: season.id,
            seasonName: season.name,
            seasonUpdatedAt: season.updatedAt,
            eventID: event.id,
            eventDate: event.date,
            metadataDigest: metadata.semanticDigest,
            intentIDs: intents.map(\PlannedSessionIntentRecord.id),
            intentPayloads: intents.map(\PlannedSessionIntentRecord.strengthTargetsJSON)
        )
    }

    private func emptyIntent(id: String,
                             sessionID: UUID,
                             planID: UUID,
                             seasonID: UUID) -> PlannedSessionIntentRecord {
        PlannedSessionIntentRecord(
            id: id,
            plannedSessionID: sessionID,
            planID: planID,
            seasonID: seasonID,
            intentVersion: 1,
            weekIndex: 0,
            dayOffset: 0,
            stimulusRaw: RunningStimulus.unstructured.rawValue,
            sessionClassRaw: RunningIntentSessionClass.easy.rawValue,
            progressionLevel: 0,
            hardClassRaw: RunningHardClass.none.rawValue,
            primaryTargetRaw: RunningTargetKind.completion.rawValue,
            fallbackTargetRaws: [],
            workDistanceM: nil,
            workDurationS: nil,
            workPaceSPerKm: nil,
            intervalPrescription: nil,
            strengthTargetsJSON: Data("[]".utf8),
            recoveryDistanceM: nil,
            recoveryDurationS: nil,
            recoveryModeRaw: nil,
            successLower: nil,
            successUpper: nil,
            recoveryCostRaw: RunningRecoveryCostBand.unknown.rawValue,
            validSubstitutionIDs: [],
            minimumCompletedExposures: 0,
            minimumConfidenceRaw: RunningEvidenceConfidence.unknown.rawValue,
            purpose: "",
            ruleIDRaws: [],
            limitationRaws: [],
            createdAt: Date()
        )
    }
}
