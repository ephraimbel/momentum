import Foundation
import Testing
@testable import Momentum

struct LegacyRoadPolicyAdapterTests {
    private enum FixtureError: Error {
        case expectedCandidate
        case expectedConflict
        case expectedProtection
    }

    private var adapter: LegacyRoadPolicyAdapter {
        LegacyRoadPolicyAdapter(catalog: RunningPlannerTestFixtures.catalog)
    }

    @Test func adapterMatchesAllReviewedLegacyPlansAndTypedPrescriptions() throws {
        for (ordinal, persona) in RunningPlannerTestFixtures.goldenPersonas.enumerated() {
            let requestID = deterministicID(ordinal + 1)
            let requestedName = "  \(persona.id) goal  "
            let request = PlanningRequest.legacy(
                id: requestID,
                inputs: persona.inputs,
                calibration: persona.calibration,
                name: requestedName,
                generatedAt: RunningPlannerTestFixtures.startDate,
                startDate: RunningPlannerTestFixtures.startDate,
                calendar: RunningPlannerTestFixtures.calendar
            )
            let candidate = try candidate(from: adapter.evaluate(request))
            let direct = PlanEngine.generate(
                profile: persona.inputs,
                catalog: RunningPlannerTestFixtures.catalog,
                calibration: persona.calibration,
                startDate: RunningPlannerTestFixtures.startDate,
                calendar: RunningPlannerTestFixtures.calendar
            )

            #expect(candidate.plan == direct, "Legacy value mismatch for \(persona.id)")
            #expect(candidate.semanticSnapshot == direct.semanticSnapshot())
            #expect(candidate.semanticDigest.value == persona.expectedDigest)
            #expect(candidate.plan.goalRacePaceSPerKm == direct.goalRacePaceSPerKm)
            #expect(candidate.planName == "\(persona.id) goal")
            #expect(candidate.selectedPolicyID == expectedPolicy(for: persona.family))
            #expect(candidate.requestID == requestID)
            #expect(candidate.seasonID == request.season.id)
            #expect(candidate.rulesetID == PlanningRequest.legacyRulesetID)
            #expect(candidate.validation.isValid)
            #expect(candidate.differenceFromExisting == nil)
            #expect(candidate.trace.status == .candidate)
            #expect(candidate.trace.policyID == candidate.selectedPolicyID)
            #expect(candidate.trace.unknownRuleIDs(in: .legacyRoadV1).isEmpty)

            let expectedWeeks = direct.weeks.map(\.index)
            #expect(candidate.weeklyDoses.map(\.weekIndex) == expectedWeeks)
            #expect(candidate.blocks.flatMap { Array($0.firstWeekIndex...$0.lastWeekIndex) } == expectedWeeks)

            let generatedSessions = direct.weeks.flatMap { week in
                week.sessions.map { (week.index, $0) }
            }
            #expect(candidate.sessionIntents.count == generatedSessions.count)
            #expect(Set(candidate.sessionIntents.map(\.id)).count == generatedSessions.count)
            for index in generatedSessions.indices {
                let (weekIndex, generated) = generatedSessions[index]
                let intent = candidate.sessionIntents[index]
                #expect(intent.weekIndex == weekIndex)
                #expect(intent.dayOffset == generated.dayOffset)
                #expect(intent.discipline == generated.discipline)
                #expect(intent.legacyRunType == generated.runType)
                #expect(intent.workDose.distanceM == generated.targetDistanceM)
                #expect(intent.workDose.durationS == generated.targetDurationS)
                #expect(intent.workDose.paceSPerKm == generated.targetPaceSPerKm)
                #expect(intent.workDose.intervalPrescription == generated.intervals)
                #expect(intent.workDose.strengthTargets == generated.strengthTargets.map(RunningStrengthTarget.init))
            }
        }
    }

    @Test func adapterPreservesExactRunnerStrengthOrderAndPrescription() throws {
        let persona = try #require(fixture(named: "road.10k-strength-support"))
        let request = legacyRequest(persona, name: "10K strength support")
        let candidate = try candidate(from: adapter.evaluate(request))
        let generated = candidate.plan.weeks.flatMap(\.sessions).filter { $0.discipline == .strength }
        let intents = candidate.sessionIntents.filter { $0.discipline == .strength }

        #expect(!generated.isEmpty)
        #expect(intents.count == generated.count)
        for index in generated.indices {
            #expect(intents[index].workDose.strengthTargets == generated[index].strengthTargets.map(RunningStrengthTarget.init))
            #expect(intents[index].targetHierarchy.primary == .strengthPrescription)
            #expect(intents[index].ruleIDs.contains(.strengthSupport))
        }
    }

    @Test func imperialPrescriptionsRemainExactlyOnTheReviewedLegacyOutput() throws {
        let persona = try #require(fixture(named: "half.imperial-hybrid"))
        let request = legacyRequest(persona, name: "Imperial half")
        let candidate = try candidate(from: adapter.evaluate(request))
        let direct = PlanEngine.generate(
            profile: persona.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: persona.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )

        #expect(request.displayUnit == .imperial)
        #expect(candidate.plan == direct)
        #expect(candidate.semanticDigest.value == persona.expectedDigest)
        #expect(candidate.trace.appliedRuleIDs.contains(.displayRounding))
    }

    @Test func completedCarryoverMatchesTheShippingPersistenceBoundary() throws {
        let persona = try #require(fixture(named: "road.10k-recreational"))
        let calendar = RunningPlannerTestFixtures.calendar
        let monday = RunningPlannerTestFixtures.startDate
        let thursday = try #require(calendar.date(byAdding: .day, value: 3, to: monday))
        let raceSevenWeeksAgo = try #require(calendar.date(byAdding: .weekOfYear, value: -7, to: thursday))
        let raceNineWeeksAgo = try #require(calendar.date(byAdding: .weekOfYear, value: -9, to: thursday))
        let sundayBefore = try #require(calendar.date(byAdding: .day, value: -1, to: monday))
        let friday = try #require(calendar.date(byAdding: .day, value: 1, to: thursday))

        let recentRaceID = deterministicID(201)
        let mondayID = deterministicID(202)
        let thursdayID = deterministicID(203)
        let existing = ExistingRunningPlanSnapshot(
            id: deterministicID(200),
            name: "Existing plan",
            isSelfCoached: false,
            sessions: [
                .init(id: deterministicID(204), date: friday, status: .completed,
                      discipline: .running, runType: .easy),
                .init(id: deterministicID(205), date: sundayBefore, status: .completed,
                      discipline: .running, runType: .easy),
                .init(id: mondayID, date: monday, status: .completed,
                      discipline: .running, runType: .easy),
                .init(id: deterministicID(206), date: monday, status: .missed,
                      discipline: .running, runType: .tempo),
                .init(id: thursdayID, date: thursday, status: .completed,
                      discipline: .strength, runType: nil),
                .init(id: recentRaceID, date: raceSevenWeeksAgo, status: .completed,
                      discipline: .running, runType: .race),
                .init(id: deterministicID(207), date: raceNineWeeksAgo, status: .completed,
                      discipline: .running, runType: .race),
            ]
        )
        let request = PlanningRequest.legacy(
            id: deterministicID(208),
            inputs: persona.inputs,
            calibration: persona.calibration,
            name: "Replacement",
            generatedAt: thursday,
            startDate: thursday,
            calendar: calendar,
            trigger: .athleteAdjustment,
            authority: .athleteRequestedCoaching,
            existingPlan: existing
        )
        let candidate = try candidate(from: adapter.evaluate(request))

        #expect(candidate.carriedCompletedSessionIDs == [recentRaceID, mondayID, thursdayID])
    }

    @Test func automaticAndShadowPlanningCannotRewriteASelfCoachedPlan() throws {
        let persona = try #require(fixture(named: "road.10k-recreational"))
        let selfCoached = ExistingRunningPlanSnapshot(
            id: deterministicID(300),
            name: "My own sessions",
            isSelfCoached: true
        )

        for authority in [RunningPlanningAuthority.automaticCoach, .shadowOnly] {
            let base = PlanningRequest.legacy(
                id: deterministicID(authority == .automaticCoach ? 301 : 302),
                inputs: persona.inputs,
                calibration: persona.calibration,
                name: "Should not replace",
                generatedAt: RunningPlannerTestFixtures.startDate,
                startDate: RunningPlannerTestFixtures.startDate,
                calendar: RunningPlannerTestFixtures.calendar,
                trigger: authority == .automaticCoach ? .automaticAdaptation : .shadowEvaluation,
                authority: authority,
                existingPlan: selfCoached
            )
            // Protection is checked before adapter inputs so even a malformed automatic request
            // cannot use an error path to bypass athlete ownership.
            let request = removingLegacyBridge(from: base)
            let protected = try protectedResult(from: adapter.evaluate(request))
            #expect(protected.existingPlanID == selfCoached.id)
            #expect(protected.planName == selfCoached.name)
            #expect(protected.trace.status == .protected)
            #expect(protected.trace.hardConstraints.contains(.selfCoachedOwnership))
            #expect(protected.trace.appliedRuleIDs == [.selfCoachedBoundary])
        }
    }

    @Test func explicitAthleteRequestCanReplaceSelfCoachedPlanAndKeepsRequestedName() throws {
        let persona = try #require(fixture(named: "road.10k-recreational"))
        let existing = ExistingRunningPlanSnapshot(
            id: deterministicID(310),
            name: "My own sessions",
            isSelfCoached: true
        )
        let request = PlanningRequest.legacy(
            id: deterministicID(311),
            inputs: persona.inputs,
            calibration: persona.calibration,
            name: "  Coached 10K build  ",
            generatedAt: RunningPlannerTestFixtures.startDate,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar,
            trigger: .athleteAdjustment,
            authority: .athleteRequestedCoaching,
            existingPlan: existing
        )
        let candidate = try candidate(from: adapter.evaluate(request))

        #expect(candidate.planName == "Coached 10K build")
        #expect(candidate.trace.hardConstraints.contains(.selfCoachedOwnership))
    }

    @Test func blankReplacementNameFallsBackToTheExistingAthleteName() throws {
        let persona = try #require(fixture(named: "road.10k-recreational"))
        let existing = ExistingRunningPlanSnapshot(
            id: deterministicID(320),
            name: "  Autumn 10K  ",
            isSelfCoached: false
        )
        let request = PlanningRequest.legacy(
            id: deterministicID(321),
            inputs: persona.inputs,
            calibration: persona.calibration,
            name: "   ",
            generatedAt: RunningPlannerTestFixtures.startDate,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar,
            trigger: .athleteAdjustment,
            authority: .athleteRequestedCoaching,
            existingPlan: existing
        )
        let candidate = try candidate(from: adapter.evaluate(request))

        #expect(candidate.planName == "Autumn 10K")
    }

    @Test func unsupportedRequestsReturnTypedConflictsWithoutGeneratingANeighboringPolicy() throws {
        let baseline = try #require(fixture(named: "road.10k-recreational"))

        var invalidDays = baseline.inputs
        invalidDays.daysPerWeek = 8
        #expect(try conflictCodes(for: legacyRequest(invalidDays)).contains(.invalidAvailability))

        var podium = baseline.inputs
        podium.daysPerWeek = 4
        podium.intensity = .podium
        #expect(try conflictCodes(for: legacyRequest(podium)).contains(.intensityRequiresMoreDays))

        var missingDistance = baseline.inputs
        missingDistance.goal = .raceDistance
        missingDistance.raceDistanceM = nil
        #expect(try conflictCodes(for: legacyRequest(missingDistance)).contains(.missingRaceDistance))

        var ultra = baseline.inputs
        ultra.raceDistanceM = 50_000
        #expect(try conflictCodes(for: legacyRequest(ultra)).contains(.unsupportedDistance))

        var cycling = baseline.inputs
        cycling.disciplines = [.cycling]
        #expect(try conflictCodes(for: legacyRequest(cycling)).contains(.unsupportedDiscipline))

        let roadRequest = legacyRequest(baseline, name: "Road goal")
        let roadEvent = try #require(roadRequest.season.primaryEvent)
        let trailEvent = RunningSeasonEvent(
            id: roadEvent.id,
            name: roadEvent.name,
            date: roadEvent.date,
            distanceM: roadEvent.distanceM,
            durationS: roadEvent.durationS,
            priority: roadEvent.priority,
            surface: .trail
        )
        let trailSeason = RunningSeason(
            id: roadRequest.season.id,
            name: roadRequest.season.name,
            status: roadRequest.season.status,
            primaryOutcome: roadRequest.season.primaryOutcome,
            motivations: roadRequest.season.motivations,
            events: [trailEvent]
        )
        #expect(try conflictCodes(for: replacing(roadRequest, season: trailSeason)).contains(.unsupportedSurface))

        let secondEvent = RunningSeasonEvent(
            id: deterministicID(401),
            name: "Second A race",
            date: roadEvent.date.addingTimeInterval(86_400),
            distanceM: 5_000,
            priority: .a
        )
        let twoPrimarySeason = RunningSeason(
            id: roadRequest.season.id,
            name: roadRequest.season.name,
            status: roadRequest.season.status,
            primaryOutcome: roadRequest.season.primaryOutcome,
            motivations: roadRequest.season.motivations,
            events: [roadEvent, secondEvent]
        )
        #expect(try conflictCodes(for: replacing(roadRequest, season: twoPrimarySeason)).contains(.multiplePrimaryEvents))

        let pastEvent = RunningSeasonEvent(
            id: roadEvent.id,
            name: roadEvent.name,
            date: RunningPlannerTestFixtures.startDate.addingTimeInterval(-86_400),
            distanceM: roadEvent.distanceM,
            durationS: roadEvent.durationS,
            priority: .a
        )
        let pastSeason = RunningSeason(
            id: roadRequest.season.id,
            name: roadRequest.season.name,
            status: roadRequest.season.status,
            primaryOutcome: roadRequest.season.primaryOutcome,
            motivations: roadRequest.season.motivations,
            events: [pastEvent]
        )
        #expect(try conflictCodes(for: replacing(roadRequest, season: pastSeason)).contains(.primaryEventInPast))

        let restriction = ActiveRunningRestriction(
            id: deterministicID(402),
            kind: .easyOnly,
            source: .athlete,
            startsAt: RunningPlannerTestFixtures.startDate,
            endsAt: nil,
            maximum: nil
        )
        #expect(try conflictCodes(for: replacing(roadRequest, activeRestrictions: [restriction]))
            .contains(.activeRestrictionUnsupported))

        let mismatchedGoal = RunningGoalContract(
            outcome: roadRequest.goal.outcome,
            targetDistanceM: 5_000,
            targetDurationS: roadRequest.goal.targetDurationS
        )
        #expect(try conflictCodes(for: replacing(roadRequest, goal: mismatchedGoal)).contains(.goalMismatch))

        #expect(try conflictCodes(for: replacing(roadRequest, rulesetID: "unknown-rules"))
            == [.rulesetMismatch])
    }

    @Test func duplicateDomainAndLegacyInputsMustAgreeInsteadOfSilentlyDroppingEdits() throws {
        let persona = try #require(fixture(named: "road.10k-recreational"))
        let request = legacyRequest(persona, name: "Road goal")

        let changedDays = RunningAvailability(
            trainingDaysPerWeek: request.availability.trainingDaysPerWeek + 1,
            preferredWeekdays: request.availability.preferredWeekdays,
            preferredDayOffsets: request.availability.preferredDayOffsets,
            fixedDates: request.availability.fixedDates,
            sessionTimeCeilingS: request.availability.sessionTimeCeilingS,
            equipment: request.availability.equipment,
            overrides: request.availability.overrides
        )
        #expect(try conflictCodes(for: replacing(request, availability: changedDays))
            .contains(.availabilityMismatch))

        let fixedCalendar = RunningAvailability(
            trainingDaysPerWeek: request.availability.trainingDaysPerWeek,
            preferredWeekdays: [2],
            preferredDayOffsets: request.availability.preferredDayOffsets,
            fixedDates: [RunningFixedDate(
                id: deterministicID(450),
                date: request.startDate.addingTimeInterval(2 * 86_400),
                kind: .unavailable
            )],
            sessionTimeCeilingS: request.availability.sessionTimeCeilingS,
            equipment: request.availability.equipment,
            overrides: request.availability.overrides
        )
        #expect(try conflictCodes(for: replacing(request, availability: fixedCalendar))
            .contains(.unsupportedAvailabilityConstraint))

        let changedPreferences = RunningAvailability(
            trainingDaysPerWeek: request.availability.trainingDaysPerWeek,
            preferredWeekdays: request.availability.preferredWeekdays,
            preferredDayOffsets: request.availability.preferredDayOffsets,
            fixedDates: request.availability.fixedDates,
            sessionTimeCeilingS: request.availability.sessionTimeCeilingS,
            equipment: request.availability.equipment,
            overrides: RunningAthleteOverrides(
                intensity: .gentle,
                targetWeeklyDistanceM: request.availability.overrides.targetWeeklyDistanceM,
                hybridPriority: request.availability.overrides.hybridPriority,
                strengthSplit: request.availability.overrides.strengthSplit,
                muscleFocus: request.availability.overrides.muscleFocus
            )
        )
        #expect(try conflictCodes(for: replacing(request, availability: changedPreferences))
            .contains(.preferenceMismatch))

        #expect(try conflictCodes(for: replacing(request, displayUnit: .imperial))
            .contains(.displayUnitMismatch))

        let changedGoal = RunningGoalContract(
            outcome: request.goal.outcome,
            targetDistanceM: request.goal.targetDistanceM,
            targetDurationS: 3_600
        )
        #expect(try conflictCodes(for: replacing(request, goal: changedGoal)).contains(.goalMismatch))

        let event = try #require(request.season.primaryEvent)
        let movedEvent = RunningSeasonEvent(
            id: event.id,
            name: event.name,
            date: event.date.addingTimeInterval(86_400),
            distanceM: event.distanceM,
            durationS: event.durationS,
            priority: event.priority
        )
        let movedSeason = RunningSeason(
            id: request.season.id,
            name: request.season.name,
            status: request.season.status,
            primaryOutcome: request.season.primaryOutcome,
            motivations: request.season.motivations,
            events: [movedEvent]
        )
        #expect(try conflictCodes(for: replacing(request, season: movedSeason)).contains(.eventMismatch))

        let courseEvent = RunningSeasonEvent(
            id: event.id,
            name: event.name,
            date: event.date,
            distanceM: event.distanceM,
            durationS: event.durationS,
            priority: event.priority,
            ascentM: 250,
            climate: .high
        )
        let courseSeason = RunningSeason(
            id: request.season.id,
            name: request.season.name,
            status: request.season.status,
            primaryOutcome: request.season.primaryOutcome,
            motivations: request.season.motivations,
            events: [courseEvent]
        )
        #expect(try conflictCodes(for: replacing(request, season: courseSeason))
            .contains(.unsupportedEventConstraint))

        var invalidAggregate = persona.inputs
        invalidAggregate.currentWeeklyVolumeM = .nan
        #expect(try conflictCodes(for: legacyRequest(invalidAggregate)).contains(.invalidLegacyInput))
    }

    @Test func feasibilityIsAnExactTypedProjectionOfTheShippingVerdict() throws {
        let persona = try #require(fixture(named: "marathon.short-runway"))
        let request = legacyRequest(persona, name: "Short runway")
        let result = adapter.feasibility(for: request)
        let weeks = PlanEngine.weeksToRace(
            startDate: request.startDate,
            raceDate: persona.inputs.raceDate,
            calendar: RunningPlannerTestFixtures.calendar
        ) ?? 999
        let expected = PlanFeasibility.assess(
            raceDistanceM: persona.inputs.raceDistanceM,
            goalFinishTimeS: persona.inputs.goalFinishTimeS,
            currentP5kSPerKm: persona.calibration.estimatedP5kSPerKm,
            currentWeeklyVolumeM: persona.inputs.currentWeeklyVolumeM ?? 0,
            weeksAvailable: weeks,
            experience: persona.inputs.runningExperience,
            injuryProne: !persona.inputs.injuryHistory.isEmpty,
            daysPerWeek: persona.inputs.daysPerWeek,
            intensity: persona.inputs.intensity,
            targetWeeklyVolumeM: persona.inputs.targetWeeklyVolumeM
        )

        #expect(result.verdict.rawValue == expected.verdict.rawValue)
        #expect(result.weeksAvailable == expected.weeksAvailable)
        #expect(result.weeksNeeded == expected.weeksNeeded)
        #expect(result.recommendedIntensity == expected.recommended)
        #expect(result.realisticFinishS == expected.realisticFinishS)
        #expect(result.weeklyCapShortfallM == expected.weeklyCapShortfallM)
        #expect(result.headline == expected.headline)
        #expect(result.detail == expected.detail)
        #expect(result.options == expected.options)
        #expect(result.conflicts.isEmpty)
    }

    @Test func undatedBasePlanKeepsNoRaceSemantics() throws {
        let persona = try #require(fixture(named: "start.first-steps.3d"))
        let result = adapter.feasibility(for: legacyRequest(persona, name: "First steps"))

        #expect(result.verdict == .noRace)
        #expect(result.weeksAvailable == nil)
        #expect(result.weeksNeeded == nil)
        #expect(result.realisticFinishS == nil)
    }

    // MARK: Fixtures

    private func fixture(named id: String) -> RunningPlannerTestFixtures.GoldenPersona? {
        RunningPlannerTestFixtures.goldenPersonas.first { $0.id == id }
    }

    private func legacyRequest(_ persona: RunningPlannerTestFixtures.GoldenPersona,
                               name: String) -> PlanningRequest {
        let stableOrdinal = persona.id.utf8.reduce(0) { partial, byte in
            (partial &* 31 &+ Int(byte)) % 900
        }
        return PlanningRequest.legacy(
            id: deterministicID(stableOrdinal + 1_000),
            inputs: persona.inputs,
            calibration: persona.calibration,
            name: name,
            generatedAt: RunningPlannerTestFixtures.startDate,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
    }

    private func legacyRequest(_ inputs: PlanInputs) -> PlanningRequest {
        PlanningRequest.legacy(
            id: deterministicID(500),
            inputs: inputs,
            name: "Boundary fixture",
            generatedAt: RunningPlannerTestFixtures.startDate,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
    }

    private func replacing(_ request: PlanningRequest,
                           rulesetID: String? = nil,
                           displayUnit: DistanceUnit? = nil,
                           goal: RunningGoalContract? = nil,
                           season: RunningSeason? = nil,
                           availability: RunningAvailability? = nil,
                           activeRestrictions: [ActiveRunningRestriction]? = nil) -> PlanningRequest {
        PlanningRequest(
            id: request.id,
            plannerVersion: request.plannerVersion,
            rulesetID: rulesetID ?? request.rulesetID,
            generatedAt: request.generatedAt,
            startDate: request.startDate,
            calendar: request.calendar,
            displayUnit: displayUnit ?? request.displayUnit,
            trigger: request.trigger,
            authority: request.authority,
            goal: goal ?? request.goal,
            season: season ?? request.season,
            availability: availability ?? request.availability,
            athleteState: request.athleteState,
            existingPlan: request.existingPlan,
            activeRestrictions: activeRestrictions ?? request.activeRestrictions,
            legacyBridge: request.legacyBridge
        )
    }

    private func removingLegacyBridge(from request: PlanningRequest) -> PlanningRequest {
        PlanningRequest(
            id: request.id,
            plannerVersion: request.plannerVersion,
            rulesetID: request.rulesetID,
            generatedAt: request.generatedAt,
            startDate: request.startDate,
            calendar: request.calendar,
            displayUnit: request.displayUnit,
            trigger: request.trigger,
            authority: request.authority,
            goal: request.goal,
            season: request.season,
            availability: request.availability,
            athleteState: request.athleteState,
            existingPlan: request.existingPlan,
            activeRestrictions: request.activeRestrictions,
            legacyBridge: nil
        )
    }

    private func candidate(from result: LegacyRoadAdapterResult) throws -> LegacyRoadPlanCandidate {
        guard case let .candidate(candidate) = result else { throw FixtureError.expectedCandidate }
        return candidate
    }

    private func protectedResult(from result: LegacyRoadAdapterResult) throws -> LegacyRoadProtectedResult {
        guard case let .protectedSelfCoached(value) = result else { throw FixtureError.expectedProtection }
        return value
    }

    private func conflictCodes(for request: PlanningRequest) throws -> Set<RunningPlanningConflictCode> {
        guard case let .conflict(value) = try adapter.evaluate(request) else {
            throw FixtureError.expectedConflict
        }
        #expect(value.trace.status == .conflict)
        return Set(value.conflicts.map(\.code))
    }

    private func expectedPolicy(for family: RunningPlannerTestFixtures.Family) -> RunningPolicyID {
        switch family {
        case .startReturn: .startReturnRoadV1
        case .fiveKTenK: .road5K10KV1
        case .halfMarathon: .roadHalfMarathonV1
        case .marathon: .roadMarathonV1
        }
    }

    private func deterministicID(_ value: Int) -> UUID {
        let suffix = String(format: "%012x", value)
        return UUID(uuidString: "A11CE000-0000-0000-0000-\(suffix)")!
    }
}
