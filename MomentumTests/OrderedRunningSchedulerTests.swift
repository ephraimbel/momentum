import Foundation
import Testing
@testable import Momentum

struct OrderedRunningSchedulerTests {
    private let scheduler = OrderedRunningScheduler()

    @Test func hardCalendarRecoveryAndTerminalRaceConstraintsAreNeverTraded() throws {
        let start = RunningPlannerTestFixtures.startDate
        let fixedRequest = request(
            availability: RunningAvailability(
                trainingDaysPerWeek: 4,
                fixedDates: [
                    .init(id: id(10), date: day(0, from: start), kind: .unavailable),
                    .init(id: id(11), date: day(2, from: start), kind: .fixedRun),
                    .init(id: id(12), date: day(4, from: start), kind: .fixedStrength),
                ],
                equipment: .fullGym
            )
        )
        let intents = [
            intent("quality", day: 0, sessionClass: .quality, hardClass: .hardRun),
            intent("easy", day: 1),
            intent("long", day: 2, sessionClass: .long),
            intent("lower", day: 3, discipline: .strength, sessionClass: .strength,
                   hardClass: .hardLowerBodyStrength),
        ]
        let scheduled = try value(scheduler.schedule(
            weekIndex: 0,
            weekStart: start,
            intents: intents,
            request: fixedRequest
        ))
        let placements = Dictionary(uniqueKeysWithValues: scheduled.placements.map {
            ($0.intent.id, $0.scheduledDayOffset)
        })
        #expect(!Set(placements.values).contains(0))
        #expect(scheduled.placements.contains { $0.scheduledDayOffset == 2 && $0.intent.discipline == .running })
        #expect(scheduled.placements.contains { $0.scheduledDayOffset == 4 && $0.intent.discipline == .strength })
        #expect(placements["quality"] != (placements["lower"] ?? -2) + 1)
        #expect(scheduled.hardConstraints.contains(.fixedCalendar))
        #expect(scheduled.hardConstraints.contains(.lowerStrengthRecoverySpacing))

        let raceDate = day(5, from: start)
        let event = RunningSeasonEvent(
            id: id(20), name: "Goal 10K", date: raceDate, distanceM: 10_000, priority: .a
        )
        let raceRequest = replacing(
            request(),
            season: RunningSeason(
                id: id(21), name: "Goal 10K", status: .active, primaryOutcome: .finish,
                events: [event]
            )
        )
        let raceWeek = try value(scheduler.schedule(
            weekIndex: 0,
            weekStart: start,
            intents: [
                intent("race", day: 5, runType: .race, stimulus: .competition, sessionClass: .race,
                       hardClass: .hardRun),
                intent("shakeout", day: 6),
            ],
            request: raceRequest
        ))
        let racePlacement = try #require(raceWeek.placements.first { $0.intent.id == "race" })
        #expect(racePlacement.scheduledDayOffset == 5)
        #expect(raceWeek.placements.allSatisfy { $0.scheduledDayOffset <= 5 })
        #expect(raceWeek.hardConstraints.contains(.noTrainingAfterTerminalRace))
    }

    @Test func preferenceOrderIsExplicitThenSupportedAdherenceThenExistingPlacement() throws {
        let start = RunningPlannerTestFixtures.startDate
        let adherence = RunningEvidence(
            value: RunningScheduleAdherence(
                pattern: .weekdayConstrained,
                commonlyCompletedWeekdays: [5], // Thursday, offset 3 from the Monday anchor.
                commonlyMissedWeekdays: [4],
                completionFraction: 0.85
            ),
            source: .momentumWorkout,
            observedAt: start,
            sampleCount: 8,
            confidence: .moderate
        )
        let state = RunningAthleteState(scheduleAdherence: adherence)
        let existing = ExistingRunningPlanSnapshot(
            id: id(30), name: "Current", isSelfCoached: false
        )
        let explicit = request(
            availability: RunningAvailability(
                trainingDaysPerWeek: 1,
                preferredWeekdays: [4], // Wednesday, offset 2.
                equipment: .fullGym
            ),
            athleteState: state,
            existingPlan: existing
        )
        let one = [intent("easy", day: 6)]
        let explicitResult = try value(scheduler.schedule(
            weekIndex: 0, weekStart: start, intents: one, request: explicit
        ))
        #expect(explicitResult.placements.first?.scheduledDayOffset == 2)
        #expect(explicitResult.relaxedPreferences.contains(.learnedAvoidWeekday))
        #expect(explicitResult.relaxedPreferences.contains(.existingPlanPlacement))

        let learned = replacing(
            explicit,
            availability: RunningAvailability(trainingDaysPerWeek: 1, equipment: .fullGym)
        )
        let learnedResult = try value(scheduler.schedule(
            weekIndex: 0, weekStart: start, intents: one, request: learned
        ))
        #expect(learnedResult.placements.first?.scheduledDayOffset == 3)
        #expect(!learnedResult.relaxedPreferences.contains(.learnedAvoidWeekday))
        #expect(learnedResult.relaxedPreferences.contains(.existingPlanPlacement))

        let healthOnly = RunningAthleteState(scheduleAdherence: RunningEvidence(
            value: adherence.value,
            source: .healthSignal,
            observedAt: start,
            sampleCount: 30,
            confidence: .moderate
        ))
        let healthRequest = replacing(learned, athleteState: healthOnly)
        let healthResult = try value(scheduler.schedule(
            weekIndex: 0, weekStart: start, intents: one, request: healthRequest
        ))
        #expect(healthResult.placements.first?.scheduledDayOffset == 6)
        #expect(!healthResult.relaxedPreferences.contains(.learnedAvoidWeekday))
    }

    @Test func impossibleInputsReturnSpecificTypedConflicts() {
        let overBudget = replacing(
            request(),
            availability: RunningAvailability(trainingDaysPerWeek: 1, equipment: .fullGym)
        )
        #expect(conflictCodes(scheduler.schedule(
            weekIndex: 0,
            weekStart: overBudget.startDate,
            intents: [intent("one", day: 0), intent("two", day: 1)],
            request: overBudget
        )) == [.trainingDayBudgetExceeded])

        let collisionDate = day(1, from: overBudget.startDate)
        let collision = replacing(
            request(),
            availability: RunningAvailability(
                trainingDaysPerWeek: 1,
                fixedDates: [
                    .init(id: id(40), date: collisionDate, kind: .unavailable),
                    .init(id: id(41), date: collisionDate, kind: .fixedRun),
                ],
                equipment: .fullGym
            )
        )
        #expect(conflictCodes(scheduler.schedule(
            weekIndex: 0,
            weekStart: collision.startDate,
            intents: [intent("one", day: 0)],
            request: collision
        )) == [.fixedDateCollision])

        let end = day(6, from: overBudget.startDate)
        let restricted = replacing(
            request(),
            availability: RunningAvailability(trainingDaysPerWeek: 1, equipment: .fullGym),
            activeRestrictions: [ActiveRunningRestriction(
                id: id(42), kind: .noRunning, source: .athlete,
                startsAt: overBudget.startDate, endsAt: end, maximum: nil
            )]
        )
        #expect(conflictCodes(scheduler.schedule(
            weekIndex: 0,
            weekStart: restricted.startDate,
            intents: [intent("one", day: 0)],
            request: restricted
        )) == [.noFeasibleSchedule])
    }

    @Test func seededPlacementMatrixIsDeterministicAndAlwaysHardValid() throws {
        var generator = LCG(state: 0xC0FFEE)
        for caseIndex in 0..<512 {
            let count = 1 + Int(generator.next() % 6)
            var intents: [SessionIntent] = []
            for itemIndex in 0..<count {
                let kind = Int(generator.next() % 5)
                let item: SessionIntent
                switch kind {
                case 0:
                    item = intent("\(caseIndex)-\(itemIndex)", day: Int(generator.next() % 7),
                                  sessionClass: .quality, hardClass: .hardRun)
                case 1:
                    item = intent("\(caseIndex)-\(itemIndex)", day: Int(generator.next() % 7),
                                  sessionClass: .long)
                case 2:
                    item = intent("\(caseIndex)-\(itemIndex)", day: Int(generator.next() % 7),
                                  discipline: .strength, sessionClass: .strength,
                                  hardClass: .hardLowerBodyStrength)
                default:
                    item = intent("\(caseIndex)-\(itemIndex)", day: Int(generator.next() % 7))
                }
                intents.append(item)
            }
            let preferred: Set<Int> = [Int(generator.next() % 7), Int(generator.next() % 7)]
            let availability = RunningAvailability(
                trainingDaysPerWeek: count,
                preferredDayOffsets: preferred,
                equipment: .fullGym
            )
            let input = request(availability: availability)
            let first = scheduler.schedule(
                weekIndex: 0, weekStart: input.startDate, intents: intents, request: input
            )
            let second = scheduler.schedule(
                weekIndex: 0, weekStart: input.startDate, intents: intents, request: input
            )
            #expect(first == second, "Non-deterministic schedule at seed case \(caseIndex)")
            let scheduled = try value(first)
            let days = scheduled.placements.map(\.scheduledDayOffset)
            #expect(days.count == count)
            #expect(Set(days).count == count)
            #expect(days.allSatisfy { (0...6).contains($0) })
            for lower in scheduled.placements where lower.intent.hardClass == .hardLowerBodyStrength {
                #expect(!scheduled.placements.contains {
                    $0.intent.hardClass == .hardRun
                        && $0.scheduledDayOffset == lower.scheduledDayOffset + 1
                })
            }
        }
    }
}

private extension OrderedRunningSchedulerTests {
    enum FixtureError: Error { case expectedSchedule }

    struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    func request(availability: RunningAvailability? = nil,
                 athleteState: RunningAthleteState = .unknown,
                 existingPlan: ExistingRunningPlanSnapshot? = nil) -> PlanningRequest {
        let persona = RunningPlannerTestFixtures.goldenPersonas.first {
            $0.id == "road.10k-recreational"
        }!
        let base = PlanningRequest.legacy(
            id: id(1),
            inputs: persona.inputs,
            calibration: persona.calibration,
            name: "Scheduler fixture",
            generatedAt: RunningPlannerTestFixtures.startDate,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar,
            existingPlan: existingPlan,
            athleteState: athleteState
        )
        return replacing(base, availability: availability)
    }

    func replacing(_ request: PlanningRequest,
                   season: RunningSeason? = nil,
                   availability: RunningAvailability? = nil,
                   athleteState: RunningAthleteState? = nil,
                   existingPlan: ExistingRunningPlanSnapshot? = nil,
                   activeRestrictions: [ActiveRunningRestriction]? = nil) -> PlanningRequest {
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
            season: season ?? request.season,
            availability: availability ?? request.availability,
            athleteState: athleteState ?? request.athleteState,
            existingPlan: existingPlan ?? request.existingPlan,
            activeRestrictions: activeRestrictions ?? request.activeRestrictions,
            legacyBridge: request.legacyBridge
        )
    }

    func intent(_ id: String,
                day: Int,
                discipline: Discipline = .running,
                runType: RunType? = .easy,
                stimulus: RunningStimulus = .aerobicEndurance,
                sessionClass: RunningIntentSessionClass = .easy,
                hardClass: RunningHardClass = .none) -> SessionIntent {
        SessionIntent(
            id: id,
            version: 1,
            weekIndex: 0,
            dayOffset: day,
            discipline: discipline,
            legacyRunType: discipline == .running ? runType : nil,
            stimulus: discipline == .strength ? .strengthSupport : stimulus,
            sessionClass: sessionClass,
            progressionLevel: 0,
            hardClass: hardClass,
            targetHierarchy: RunningTargetHierarchy(
                primary: discipline == .strength ? .strengthPrescription : .effort,
                fallbacks: discipline == .strength ? [] : [.distance]
            ),
            workDose: RunningWorkDose(
                distanceM: discipline == .running ? 5_000 : nil,
                durationS: nil,
                paceSPerKm: discipline == .running ? 360 : nil,
                intervalPrescription: nil,
                strengthTargets: []
            ),
            recoveryDose: nil,
            successRange: nil,
            expectedRecoveryCost: hardClass == .none ? .low : .high,
            validSubstitutionIDs: [],
            minimumEvidenceToProgress: .init(minimumCompletedExposures: 1, minimumConfidence: .low),
            purpose: "Scheduler test intent",
            ruleIDs: [.calendarScheduling],
            limitations: []
        )
    }

    func value(_ result: RunningSchedulingResult) throws -> RunningScheduledWeek {
        guard case let .scheduled(value) = result else {
            Issue.record("Expected a hard-valid schedule, got \(result)")
            throw FixtureError.expectedSchedule
        }
        return value
    }

    func conflictCodes(_ result: RunningSchedulingResult) -> [RunningPlanningConflictCode] {
        guard case let .conflict(conflicts) = result else {
            Issue.record("Expected a typed scheduling conflict")
            return []
        }
        return conflicts.map(\.code)
    }

    func day(_ offset: Int, from start: Date) -> Date {
        RunningPlannerTestFixtures.calendar.date(byAdding: .day, value: offset, to: start)!
    }

    func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
