import Foundation
import SwiftData
import Testing
@testable import Momentum

@Suite(.serialized)
@MainActor
struct PlanStoreTests {
    private enum InjectedFailure: Error { case beforeSave }

    private struct SeedIDs: Sendable {
        let profile: UUID
        let oldPlan: UUID
        let completedSession: UUID
        let openSession: UUID
        let workout: UUID
    }

    private struct Fixture {
        let input: PlanStore.Commit
        let ids: SeedIDs
    }

    private var calendar: Calendar { RunningPlannerTestFixtures.calendar }
    private var startDate: Date { RunningPlannerTestFixtures.startDate }

    @Test func configurationCommandDualWritesAndBecomesIdempotent() throws {
        let container = try inMemoryContainer()
        let persona = try persona(named: "road.10k-recreational")
        let ids = try seedLegacyPlan(persona: persona, in: container)
        _ = try RunningPlanBackfill.repair(in: container, now: startDate, calendar: calendar)

        let read = ModelContext(container)
        let season = try #require(try read.fetch(FetchDescriptor<RunningSeasonRecord>()).first)
        let command = try PlanConfigurationCommand.legacyUICommand(
            id: stableID(900),
            profile: try #require(try read.fetch(FetchDescriptor<UserProfile>()).first),
            startsNewSeason: false,
            planName: "  Year-round base  ",
            goal: .endurance,
            raceDate: nil,
            raceDistanceM: nil,
            goalFinishTimeS: nil,
            in: read
        )
        #expect(command.season.id == season.id)

        let first = try command.execute(in: read, now: startDate.addingTimeInterval(100))
        #expect(first.didSave)
        #expect(first.activePlanID == ids.oldPlan)

        var verify = ModelContext(container)
        let profile = try #require(try verify.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(profile.goal == .endurance)
        #expect(profile.raceDate == nil)
        #expect(profile.raceDistanceM == nil)
        #expect(profile.goalFinishTimeS == nil)
        #expect(profile.plan?.name == "Year-round base")
        #expect(profile.plan?.goal == .endurance)
        #expect(profile.plan?.raceDate == nil)
        let updatedSeason = try #require(try verify.fetch(FetchDescriptor<RunningSeasonRecord>()).first)
        #expect(updatedSeason.name == "Year-round base")
        #expect(updatedSeason.primaryOutcomeRaw == RunningPrimaryOutcome.buildBase.rawValue)
        #expect(updatedSeason.motivationRaws == [
            RunningMotivation.health.rawValue,
            RunningMotivation.performance.rawValue,
        ])
        #expect(updatedSeason.backfillVersion == 0)
        let oldEvent = try #require(try verify.fetch(FetchDescriptor<RunningEventRecord>()).first)
        #expect(oldEvent.statusRaw == RunningEventStatus.withdrawn.rawValue)

        verify = ModelContext(container)
        let second = try command.execute(in: verify, now: startDate.addingTimeInterval(200))
        #expect(!second.didSave)
        _ = try RunningPlanBackfill.repair(
            in: container,
            now: startDate.addingTimeInterval(300),
            calendar: calendar
        )
        let afterMaintenance = ModelContext(container)
        #expect(try afterMaintenance.fetch(FetchDescriptor<RunningSeasonRecord>()).first?.name == "Year-round base")
        #expect(try afterMaintenance.fetch(FetchDescriptor<RunningEventRecord>()).first?.statusRaw
            == RunningEventStatus.withdrawn.rawValue)
    }

    @Test func candidateCommitIsOneAtomicReplacementAndRequestReplayIsANoOp() throws {
        let container = try inMemoryContainer()
        let fixture = try makeFixture(in: container)
        var observedDirectSwap = false

        let receipt = try PlanStore.commit(
            fixture.input,
            in: container.mainContext,
            now: startDate.addingTimeInterval(500),
            hooks: PlanStore.Hooks(afterProfileSwap: { profile, old, new in
                observedDirectSwap = true
                #expect(old?.id == fixture.ids.oldPlan)
                #expect(profile.plan?.id == new.id)
                #expect(profile.plan?.id != fixture.ids.oldPlan)
            })
        )
        #expect(observedDirectSwap)
        #expect(receipt.didCommit)
        #expect(receipt.requestID == fixture.input.request.id)
        #expect(receipt.seasonID == fixture.input.candidate.seasonID)

        try assertCommittedGraph(receipt: receipt, fixture: fixture, in: container)
        let counts = try sidecarCounts(in: ModelContext(container))

        let replay = try PlanStore.commit(
            fixture.input,
            in: container.mainContext,
            now: startDate.addingTimeInterval(900)
        )
        #expect(!replay.didCommit)
        #expect(replay.planID == receipt.planID)
        #expect(try sidecarCounts(in: ModelContext(container)) == counts)
        try assertCommittedGraph(receipt: replay, fixture: fixture, in: container)
    }

    @Test func legacyCreateAdjustPathReconcilesReplacementSidecarsImmediately() throws {
        let container = try inMemoryContainer()
        let persona = try persona(named: "road.10k-recreational")
        let ids = try seedLegacyPlan(persona: persona, in: container)
        _ = try RunningPlanBackfill.repair(in: container, now: startDate, calendar: calendar)

        let context = container.mainContext
        let profile = try #require(try context.fetch(FetchDescriptor<UserProfile>()).first)
        let oldSeasonID = try #require(
            try context.fetch(FetchDescriptor<RunningSeasonRecord>()).first?.id
        )
        let command = try PlanConfigurationCommand.legacyUICommand(
            id: stableID(901),
            profile: profile,
            startsNewSeason: false,
            planName: "Adjusted 10K",
            goal: profile.goal,
            raceDate: profile.raceDate,
            raceDistanceM: profile.raceDistanceM,
            goalFinishTimeS: profile.goalFinishTimeS,
            in: context
        )

        PlanService.rebuild(for: profile, startDate: startDate, in: context)
        let replacementID = try #require(profile.plan?.id)
        #expect(replacementID != ids.oldPlan)
        _ = try command.execute(in: context, now: startDate.addingTimeInterval(200))
        _ = try RunningPlanBackfill.repairAfterLegacyPlanMutation(
            in: context,
            now: startDate.addingTimeInterval(300),
            calendar: calendar
        )

        let read = ModelContext(container)
        let current = try #require(try read.fetch(FetchDescriptor<UserProfile>()).first?.plan)
        #expect(current.id == replacementID)
        #expect(current.name == "Adjusted 10K")
        #expect(try read.fetchCount(FetchDescriptor<TrainingPlan>()) == 1)
        let season = try #require(try read.fetch(FetchDescriptor<RunningSeasonRecord>()).first {
            $0.id == oldSeasonID
        })
        #expect(season.activePlanID == replacementID)
        #expect(season.backfillVersion == 0)
        let metadata = try read.fetch(FetchDescriptor<PlanMetadataRecord>())
        #expect(metadata.count == 1)
        #expect(metadata.first?.planID == replacementID)
        #expect(metadata.first?.seasonID == oldSeasonID)
        let intents = try read.fetch(FetchDescriptor<PlannedSessionIntentRecord>())
        #expect(!intents.isEmpty)
        #expect(Set(intents.map(\PlannedSessionIntentRecord.planID)) == [replacementID])
        #expect(!intents.contains { $0.plannedSessionID == ids.openSession })
        let carried = try #require(current.sessions.first { $0.id == ids.completedSession })
        #expect(carried.completedWorkout?.id == ids.workout)
    }

    @Test func injectedFailureRollsBackOnDiskAndOldPlanReopensIntact() throws {
        // SwiftData exposes no explicit close. Delete fixtures from the previous test process before
        // opening this run's store; unlinking the current SQLite/WAL in a defer block is an API
        // violation even after local ModelContainer references have been released.
        try removeStaleDiskFixtures()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("momentum-plan-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("candidate.store")

        let fixture: Fixture = try {
            let container = try diskContainer(at: storeURL)
            let value = try makeFixture(in: container)
            do {
                _ = try PlanStore.commit(
                    value.input,
                    in: container.mainContext,
                    hooks: PlanStore.Hooks(
                        afterProfileSwap: { profile, old, new in
                            #expect(old?.id == value.ids.oldPlan)
                            #expect(profile.plan?.id == new.id)
                        },
                        beforeSave: { throw InjectedFailure.beforeSave }
                    )
                )
                Issue.record("Expected the injected candidate save failure")
            } catch is InjectedFailure {
                // Expected: PlanStore owns rollback.
            }
            let sameProcess = ModelContext(container)
            #expect(try sameProcess.fetch(FetchDescriptor<UserProfile>()).first?.plan?.id == value.ids.oldPlan)
            #expect(try sameProcess.fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)
            return value
        }()

        // Reopen the SQLite store with a new container: rollback must be durable, not just an
        // apparently-correct object graph left in one ModelContext's cache.
        var reopened: ModelContainer? = try diskContainer(at: storeURL)
        do {
            let active = try #require(reopened)
            let read = ModelContext(active)
            let profile = try #require(try read.fetch(FetchDescriptor<UserProfile>()).first)
            #expect(profile.id == fixture.ids.profile)
            #expect(profile.plan?.id == fixture.ids.oldPlan)
            #expect(profile.plan?.name == "Spring 10K")
            #expect(profile.plan?.sessions.count == 2)
            let completed = try #require(profile.plan?.sessions.first { $0.id == fixture.ids.completedSession })
            #expect(completed.completedWorkout?.id == fixture.ids.workout)
            #expect(completed.completedWorkout?.plannedSession?.id == fixture.ids.completedSession)
            #expect(try read.fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)
            #expect(try read.fetchCount(FetchDescriptor<TrainingPlan>()) == 1)
            #expect(try read.fetch(FetchDescriptor<PlanMetadataRecord>()).first?.planID == fixture.ids.oldPlan)

            let retry = try PlanStore.commit(
                fixture.input,
                in: active.mainContext,
                now: startDate.addingTimeInterval(1_000)
            )
            #expect(retry.didCommit)
            try assertCommittedGraph(receipt: retry, fixture: fixture, in: active)
        }
        // The directory is reclaimed at the next test-process start, after SQLite has closed.
        reopened = nil
    }

    @Test func staleSnapshotAndShadowAuthorityFailBeforeMutation() throws {
        let container = try inMemoryContainer()
        let fixture = try makeFixture(in: container)
        let stale = PlanningRequest(
            id: fixture.input.request.id,
            plannerVersion: fixture.input.request.plannerVersion,
            rulesetID: fixture.input.request.rulesetID,
            generatedAt: fixture.input.request.generatedAt,
            startDate: fixture.input.request.startDate,
            calendar: fixture.input.request.calendar,
            displayUnit: fixture.input.request.displayUnit,
            trigger: fixture.input.request.trigger,
            authority: fixture.input.request.authority,
            goal: fixture.input.request.goal,
            season: fixture.input.request.season,
            availability: fixture.input.request.availability,
            athleteState: fixture.input.request.athleteState,
            existingPlan: ExistingRunningPlanSnapshot(
                id: fixture.ids.oldPlan,
                name: "Stale name",
                isSelfCoached: false,
                sessions: fixture.input.request.existingPlan?.sessions ?? []
            ),
            activeRestrictions: fixture.input.request.activeRestrictions,
            legacyBridge: fixture.input.request.legacyBridge
        )
        let staleInput = PlanStore.Commit(
            profileID: fixture.input.profileID,
            request: stale,
            candidate: fixture.input.candidate,
            configuration: fixture.input.configuration
        )
        do {
            _ = try PlanStore.commit(staleInput, in: container.mainContext)
            Issue.record("Expected stale snapshot rejection")
        } catch PlanStoreError.staleCurrentPlanSnapshot {
            // Expected.
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<UserProfile>()).first?.plan?.id
            == fixture.ids.oldPlan)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)

        // A shadow request cannot be made writable by merely pairing it with a valid candidate.
        let shadowRequest = PlanningRequest(
            id: fixture.input.request.id,
            plannerVersion: fixture.input.request.plannerVersion,
            rulesetID: fixture.input.request.rulesetID,
            generatedAt: fixture.input.request.generatedAt,
            startDate: fixture.input.request.startDate,
            calendar: fixture.input.request.calendar,
            displayUnit: fixture.input.request.displayUnit,
            trigger: .shadowEvaluation,
            authority: .shadowOnly,
            goal: fixture.input.request.goal,
            season: fixture.input.request.season,
            availability: fixture.input.request.availability,
            athleteState: fixture.input.request.athleteState,
            existingPlan: fixture.input.request.existingPlan,
            activeRestrictions: fixture.input.request.activeRestrictions,
            legacyBridge: fixture.input.request.legacyBridge
        )
        let shadowInput = PlanStore.Commit(
            profileID: fixture.input.profileID,
            request: shadowRequest,
            candidate: fixture.input.candidate,
            configuration: fixture.input.configuration
        )
        do {
            _ = try PlanStore.commit(shadowInput, in: container.mainContext)
            Issue.record("Expected shadow commit rejection")
        } catch PlanStoreError.shadowRequestCannotCommit {
            // Expected.
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<UserProfile>()).first?.plan?.id
            == fixture.ids.oldPlan)
    }

    @Test func editedSessionPrescriptionRejectsAStaleCandidateEvenWithoutSemanticSnapshot() throws {
        let container = try inMemoryContainer()
        let fixture = try makeFixture(in: container)
        let expected = try #require(fixture.input.request.existingPlan)
        let shallowSemantic = ExistingRunningPlanSnapshot(
            id: expected.id,
            name: expected.name,
            isSelfCoached: expected.isSelfCoached,
            semanticPlan: nil,
            sessions: expected.sessions
        )
        let request = copyRequest(fixture.input.request, existingPlan: shallowSemantic)
        let profile = try #require(container.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
        let changed = try #require(profile.plan?.sessions.first { $0.id == fixture.ids.openSession })
        changed.targetDistanceM = (changed.targetDistanceM ?? 0) + 1_000
        try container.mainContext.save()

        do {
            _ = try PlanStore.commit(
                PlanStore.Commit(
                    profileID: fixture.input.profileID,
                    request: request,
                    candidate: fixture.input.candidate,
                    configuration: fixture.input.configuration
                ),
                in: container.mainContext
            )
            Issue.record("Expected the edited prescription to reject the stale candidate")
        } catch PlanStoreError.staleCurrentPlanSnapshot {
            // Expected.
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)
    }

    @Test func semanticPlanHeaderEditRejectsAStaleCandidate() throws {
        let container = try inMemoryContainer()
        let fixture = try makeFixture(in: container)
        let plan = try #require(container.mainContext.fetch(FetchDescriptor<UserProfile>()).first?.plan)
        plan.p5kSPerKm += 10
        try container.mainContext.save()

        do {
            _ = try PlanStore.commit(fixture.input, in: container.mainContext)
            Issue.record("Expected the semantic plan edit to reject the stale candidate")
        } catch PlanStoreError.staleCurrentPlanSnapshot {
            // Expected.
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)
    }

    @Test func nonAvailabilityProfileEditRejectsAStaleCandidate() throws {
        let container = try inMemoryContainer()
        let fixture = try makeFixture(in: container)
        let profile = try #require(container.mainContext.fetch(FetchDescriptor<UserProfile>()).first)
        profile.injuryHistory = [InjuryArea.knee.rawValue]
        try container.mainContext.save()

        do {
            _ = try PlanStore.commit(fixture.input, in: container.mainContext)
            Issue.record("Expected changed planning inputs to reject the stale candidate")
        } catch PlanStoreError.requestMismatch {
            // Expected.
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlanDecisionRecord>()) == 0)
    }

    @Test func legacyRebuildFailureRollsBackPlanAndAllSidecars() throws {
        let container = try inMemoryContainer()
        let persona = try persona(named: "road.10k-recreational")
        let ids = try seedLegacyPlan(persona: persona, in: container)
        _ = try RunningPlanBackfill.repair(in: container, now: startDate, calendar: calendar)
        let context = container.mainContext
        let profile = try #require(try context.fetch(FetchDescriptor<UserProfile>()).first)
        let command = try PlanConfigurationCommand.legacyUICommand(
            id: stableID(904),
            profile: profile,
            startsNewSeason: false,
            planName: profile.plan?.name ?? "",
            goal: profile.goal,
            raceDate: profile.raceDate,
            raceDistanceM: profile.raceDistanceM,
            goalFinishTimeS: profile.goalFinishTimeS,
            in: context
        )
        _ = try command.execute(in: context, now: startDate)
        let oldSeasonID = try #require(
            try context.fetch(FetchDescriptor<RunningSeasonRecord>()).first?.id
        )

        let replacement = PlanService.rebuild(
            for: profile,
            startDate: startDate,
            in: context,
            hooks: PlanService.Hooks(beforeSave: { throw InjectedFailure.beforeSave })
        )
        #expect(replacement == nil)

        let read = ModelContext(container)
        let reopened = try #require(try read.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(reopened.plan?.id == ids.oldPlan)
        #expect(reopened.plan?.sessions.count == 2)
        #expect(reopened.plan?.sessions.first { $0.id == ids.completedSession }?.completedWorkout?.id
            == ids.workout)
        #expect(try read.fetchCount(FetchDescriptor<TrainingPlan>()) == 1)
        #expect(try read.fetch(FetchDescriptor<RunningSeasonRecord>()).count == 1)
        #expect(try read.fetch(FetchDescriptor<RunningSeasonRecord>()).first?.id == oldSeasonID)
        #expect(try read.fetch(FetchDescriptor<RunningSeasonRecord>()).first?.activePlanID == ids.oldPlan)
        #expect(try read.fetch(FetchDescriptor<PlanMetadataRecord>()).first?.planID == ids.oldPlan)
    }

    @Test func renewalKeepsDomainOwnedSeasonAndMovesEverySidecarToReplacement() throws {
        let container = try inMemoryContainer()
        let persona = try persona(named: "road.10k-recreational")
        let ids = try seedLegacyPlan(persona: persona, in: container)
        _ = try RunningPlanBackfill.repair(in: container, now: startDate, calendar: calendar)
        let context = container.mainContext
        let profile = try #require(try context.fetch(FetchDescriptor<UserProfile>()).first)
        profile.goal = .endurance
        profile.raceDate = nil
        profile.raceDistanceM = nil
        profile.goalFinishTimeS = nil
        profile.plan?.goal = .endurance
        profile.plan?.raceDate = nil
        let command = try PlanConfigurationCommand.legacyUICommand(
            id: stableID(905),
            profile: profile,
            startsNewSeason: false,
            planName: "Year-round base",
            goal: .endurance,
            raceDate: nil,
            raceDistanceM: nil,
            goalFinishTimeS: nil,
            in: context
        )
        _ = try command.execute(in: context, now: startDate)
        let seasonID = try #require(
            try context.fetch(FetchDescriptor<RunningSeasonRecord>()).first?.id
        )
        #expect(try context.fetch(FetchDescriptor<RunningSeasonRecord>()).first?.backfillVersion == 0)

        let renewed = try #require(PlanService.renewBlock(
            for: profile,
            startDate: startDate,
            in: context,
            calendar: calendar
        ))
        #expect(renewed.id != ids.oldPlan)

        let read = ModelContext(container)
        let seasons = try read.fetch(FetchDescriptor<RunningSeasonRecord>())
        #expect(seasons.count == 1)
        #expect(seasons.first?.id == seasonID)
        #expect(seasons.first?.activePlanID == renewed.id)
        #expect(seasons.first?.backfillVersion == 0)
        let metadata = try read.fetch(FetchDescriptor<PlanMetadataRecord>())
        #expect(metadata.count == 1)
        #expect(metadata.first?.planID == renewed.id)
        #expect(metadata.first?.seasonID == seasonID)
        let intents = try read.fetch(FetchDescriptor<PlannedSessionIntentRecord>())
        #expect(!intents.isEmpty)
        #expect(Set(intents.map(\PlannedSessionIntentRecord.planID)) == [renewed.id])
        #expect(Set(intents.map(\PlannedSessionIntentRecord.seasonID)) == [seasonID])
    }

    // MARK: Fixtures

    private func makeFixture(in container: ModelContainer) throws -> Fixture {
        let persona = try persona(named: "road.10k-recreational")
        #expect(!persona.inputs.disciplines.contains(.strength))
        let ids = try seedLegacyPlan(persona: persona, in: container)
        _ = try RunningPlanBackfill.repair(in: container, now: startDate, calendar: calendar)

        let read = ModelContext(container)
        let profile = try #require(try read.fetch(FetchDescriptor<UserProfile>()).first)
        let oldPlan = try #require(profile.plan)
        let existing = ExistingRunningPlanSnapshot(
            id: oldPlan.id,
            name: oldPlan.name,
            isSelfCoached: oldPlan.isSelfCoached,
            semanticPlan: RunningPlanBackfill.persistedSemanticSnapshot(
                for: oldPlan,
                calendar: calendar
            ),
            sessions: oldPlan.sessions.map(sessionSnapshot)
        )
        let requestID = stableID(700)
        let request = PlanningRequest.legacy(
            id: requestID,
            inputs: persona.inputs,
            calibration: persona.calibration,
            name: "Autumn 10K",
            generatedAt: startDate,
            startDate: startDate,
            calendar: calendar,
            trigger: .athleteAdjustment,
            authority: .athleteRequestedCoaching,
            existingPlan: existing
        )
        let adapter = LegacyRoadPolicyAdapter(catalog: RunningPlannerTestFixtures.catalog)
        guard case let .candidate(candidate) = try adapter.evaluate(request) else {
            throw PlanStoreError.invalidCandidate("Fixture did not produce a candidate.")
        }
        #expect(candidate.carriedCompletedSessionIDs == [ids.completedSession])
        let configuration = PlanConfigurationCommand(
            id: requestID,
            profileID: ids.profile,
            season: request.season,
            planName: candidate.planName,
            legacyGoal: persona.inputs.goal,
            raceDate: persona.inputs.raceDate,
            raceDistanceM: persona.inputs.raceDistanceM,
            goalFinishTimeS: persona.inputs.goalFinishTimeS
        )
        return Fixture(
            input: PlanStore.Commit(
                profileID: ids.profile,
                request: request,
                candidate: candidate,
                configuration: configuration
            ),
            ids: ids
        )
    }

    private func seedLegacyPlan(persona: RunningPlannerTestFixtures.GoldenPersona,
                                in container: ModelContainer) throws -> SeedIDs {
        let context = container.mainContext
        let inputs = persona.inputs
        let profile = UserProfile()
        profile.id = stableID(1)
        profile.goal = inputs.goal
        profile.disciplines = inputs.disciplines.map(\Discipline.rawValue)
        profile.daysPerWeek = inputs.daysPerWeek
        profile.equipment = inputs.equipment
        profile.sessionMinutes = inputs.sessionMinutes
        profile.raceDate = inputs.raceDate
        profile.raceDistanceM = inputs.raceDistanceM
        profile.goalFinishTimeS = inputs.goalFinishTimeS
        profile.experience = [
            Discipline.running.rawValue: inputs.runningExperience.rawValue,
            Discipline.strength.rawValue: inputs.liftingExperience.rawValue,
        ]
        profile.weeklyRunVolumeM = inputs.currentWeeklyVolumeM
        profile.longestRunM = inputs.longestRunM
        profile.targetWeeklyRunVolumeM = inputs.targetWeeklyVolumeM
        profile.hybridPriority = inputs.hybridPriority?.rawValue
        profile.planIntensity = inputs.intensity.rawValue
        profile.strengthSplit = inputs.strengthSplit.rawValue
        profile.muscleFocus = inputs.muscleFocus.map(\MuscleGroup.rawValue)
        profile.injuryHistory = inputs.injuryHistory.map(\InjuryArea.rawValue)
        profile.distanceUnit = inputs.distanceUnit.rawValue
        if let age = inputs.age {
            profile.birthYear = calendar.component(.year, from: startDate) - age
        }
        let anchorWeekday = calendar.component(.weekday, from: startDate)
        profile.preferredDays = inputs.preferredDayOffsets.map {
            (($0 + anchorWeekday - 1) % 7) + 1
        }
        profile.crossTraining = []

        let oldPlan = TrainingPlan()
        oldPlan.id = stableID(2)
        oldPlan.name = "Spring 10K"
        oldPlan.goal = inputs.goal
        oldPlan.disciplines = profile.disciplines
        oldPlan.raceDate = inputs.raceDate
        oldPlan.blockStart = startDate
        oldPlan.createdAt = startDate.addingTimeInterval(-86_400)
        oldPlan.p5kSPerKm = 325
        oldPlan.weekPhases = [PlanPhase.base.rawValue]

        let completed = PlannedSession()
        completed.id = stableID(3)
        completed.date = startDate
        completed.discipline = .running
        completed.runType = .easy
        completed.targetDistanceM = 6_000
        completed.targetPaceSPerKm = 365
        completed.status = .completed

        let workout = Workout()
        workout.id = stableID(4)
        workout.type = .run
        workout.startedAt = startDate
        workout.durationS = 2_190
        workout.title = "Monday easy"
        workout.plannedSession = completed
        completed.completedWorkout = workout

        let open = PlannedSession()
        open.id = stableID(5)
        open.date = calendar.date(byAdding: .day, value: 2, to: startDate)!
        open.discipline = .running
        open.runType = .tempo
        open.targetDistanceM = 7_000
        open.targetPaceSPerKm = 330
        open.status = .planned

        oldPlan.sessions = [completed, open]
        profile.plan = oldPlan
        profile.workouts = [workout]
        context.insert(profile)
        try context.save()
        return SeedIDs(
            profile: profile.id,
            oldPlan: oldPlan.id,
            completedSession: completed.id,
            openSession: open.id,
            workout: workout.id
        )
    }

    private func assertCommittedGraph(receipt: PlanStore.Receipt,
                                      fixture: Fixture,
                                      in container: ModelContainer) throws {
        let read = ModelContext(container)
        let profile = try #require(try read.fetch(FetchDescriptor<UserProfile>()).first)
        let plan = try #require(profile.plan)
        #expect(plan.id == receipt.planID)
        #expect(plan.id != fixture.ids.oldPlan)
        #expect(plan.name == "Autumn 10K")
        #expect(plan.sessions.contains { $0.id == fixture.ids.completedSession })
        #expect(!plan.sessions.contains { $0.id == fixture.ids.openSession })
        let completed = try #require(plan.sessions.first { $0.id == fixture.ids.completedSession })
        #expect(completed.status == .completed)
        #expect(completed.completedWorkout?.id == fixture.ids.workout)
        #expect(completed.completedWorkout?.plannedSession?.id == fixture.ids.completedSession)
        #expect(try read.fetchCount(FetchDescriptor<TrainingPlan>()) == 1)
        #expect(try read.fetchCount(FetchDescriptor<Workout>()) == 1)
        #expect(try read.fetchCount(FetchDescriptor<PlanMetadataRecord>()) == 1)
        let metadata = try #require(try read.fetch(FetchDescriptor<PlanMetadataRecord>()).first)
        #expect(metadata.planID == receipt.planID)
        #expect(metadata.requestID == fixture.input.request.id)
        #expect(metadata.semanticDigest == fixture.input.candidate.semanticDigest.description)
        #expect(!metadata.isLegacyBackfill)
        let decisions = try read.fetch(FetchDescriptor<PlanDecisionRecord>())
        #expect(decisions.count == 1)
        #expect(decisions.first?.requestID == fixture.input.request.id)
        #expect(decisions.first?.planID == receipt.planID)
        #expect(decisions.first?.statusRaw == RunningDecisionStatus.committed.rawValue)
        #expect(decisions.first?.normalizedInputJSON.isEmpty == false)
        let intents = try read.fetch(FetchDescriptor<PlannedSessionIntentRecord>())
        #expect(intents.count == fixture.input.candidate.sessionIntents.count + 1)
        #expect(intents.contains { $0.plannedSessionID == fixture.ids.completedSession && $0.planID == receipt.planID })
        #expect(Set(intents.map(\PlannedSessionIntentRecord.planID)) == [receipt.planID])
        let season = try #require(try read.fetch(FetchDescriptor<RunningSeasonRecord>()).first {
            $0.id == fixture.input.candidate.seasonID
        })
        #expect(season.activePlanID == receipt.planID)
        #expect(season.name == "Autumn 10K")
        #expect(season.backfillVersion == 0)
    }

    private func sidecarCounts(in context: ModelContext) throws -> [Int] {
        [
            try context.fetchCount(FetchDescriptor<RunningSeasonRecord>()),
            try context.fetchCount(FetchDescriptor<RunningEventRecord>()),
            try context.fetchCount(FetchDescriptor<PlanMetadataRecord>()),
            try context.fetchCount(FetchDescriptor<PlannedSessionIntentRecord>()),
            try context.fetchCount(FetchDescriptor<PlanDecisionRecord>()),
        ]
    }

    private func sessionSnapshot(_ session: PlannedSession) -> ExistingRunningSessionSnapshot {
        ExistingRunningSessionSnapshot(
            id: session.id,
            date: session.date,
            status: session.status,
            discipline: session.discipline,
            sportType: session.sportType,
            runType: session.runType,
            targetDistanceM: session.targetDistanceM,
            targetDurationS: session.targetDurationS,
            targetPaceSPerKm: session.targetPaceSPerKm,
            intervals: session.intervals,
            strengthLabel: session.strengthLabel,
            strengthTargets: session.strengthTargets.map {
                ExistingRunningSessionSnapshot.StrengthTarget(
                    order: $0.order,
                    exerciseName: $0.exercise?.name ?? "",
                    targetSets: $0.targetSets,
                    targetRepLow: $0.targetRepLow,
                    targetRepHigh: $0.targetRepHigh,
                    targetRPE: $0.targetRPE,
                    targetPctRM: $0.targetPctRM,
                    progression: $0.progression
                )
            },
            completedWorkoutID: session.completedWorkout?.id
        )
    }

    private func copyRequest(_ source: PlanningRequest,
                             existingPlan: ExistingRunningPlanSnapshot?) -> PlanningRequest {
        PlanningRequest(
            id: source.id,
            plannerVersion: source.plannerVersion,
            rulesetID: source.rulesetID,
            generatedAt: source.generatedAt,
            startDate: source.startDate,
            calendar: source.calendar,
            displayUnit: source.displayUnit,
            trigger: source.trigger,
            authority: source.authority,
            goal: source.goal,
            season: source.season,
            availability: source.availability,
            athleteState: source.athleteState,
            existingPlan: existingPlan,
            activeRestrictions: source.activeRestrictions,
            legacyBridge: source.legacyBridge
        )
    }

    private func persona(named id: String) throws -> RunningPlannerTestFixtures.GoldenPersona {
        try #require(RunningPlannerTestFixtures.goldenPersonas.first { $0.id == id })
    }

    private func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func diskContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        let configuration = ModelConfiguration(
            "PlanStoreTests",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: MomentumMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private func removeStaleDiskFixtures() throws {
        let temporary = FileManager.default.temporaryDirectory
        let children = try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        )
        for child in children where child.lastPathComponent.hasPrefix("momentum-plan-store-") {
            try FileManager.default.removeItem(at: child)
        }
    }

    private func stableID(_ value: Int) -> UUID {
        UUID(uuidString: "57A0E000-0000-0000-0000-\(String(format: "%012x", value))")!
    }
}
