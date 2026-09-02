import Foundation
import Testing
@testable import Momentum

struct RoadPolicyShadowTests {
    private let planner = ShadowRoadPlanner(catalog: RunningPlannerTestFixtures.catalog)

    @Test func all32ReviewedSeasonsPassTheCompleteShadowPipeline() throws {
        for (ordinal, persona) in RunningPlannerTestFixtures.goldenPersonas.enumerated() {
            let request = legacyRequest(persona, ordinal: ordinal)
            let candidate = try value(planner.evaluate(request), persona: persona.id)
            let finalSessionCount = candidate.plan.weeks.reduce(0) { $0 + $1.sessions.count }

            #expect(candidate.selectedPolicyID == policy(for: persona.family), "Wrong policy for \(persona.id)")
            #expect(candidate.legacySemanticDigest.value == persona.expectedDigest,
                    "Legacy dose baseline drifted for \(persona.id)")
            #expect(candidate.validation.isValid, "Final invariant failure for \(persona.id)")
            #expect(candidate.semanticDigest == (try candidate.semanticSnapshot.digest()))
            #expect(candidate.trace.status == .candidate)
            #expect(candidate.trace.policyID == candidate.selectedPolicyID)
            #expect(candidate.trace.unknownRuleIDs(in: .legacyRoadV1).isEmpty)
            #expect(candidate.weeklyDoses.map(\.weekIndex) == candidate.plan.weeks.map(\.index))
            #expect(candidate.scheduledWeeks.map(\.weekIndex) == candidate.plan.weeks.map(\.index))
            #expect(candidate.executionPrescriptions.count == finalSessionCount,
                    "Every session needs one execution contract for \(persona.id)")
            #expect(Set(candidate.executionPrescriptions.map(\.sessionID)).count == finalSessionCount)
            #expect(candidate.executionPrescriptions.allSatisfy { $0.validationIssues.isEmpty })
            #expect(candidate.blocks.allSatisfy { !$0.objective.isEmpty })

            for week in candidate.plan.weeks {
                #expect(week.sessions.count <= request.availability.trainingDaysPerWeek)
                #expect(Set(week.sessions.map(\.dayOffset)).count == week.sessions.count)
                #expect(week.sessions.allSatisfy { (0...6).contains($0.dayOffset) })
                for lower in week.sessions where lower.isHardLowerLift {
                    #expect(!week.sessions.contains {
                        $0.isHardRun && $0.dayOffset == lower.dayOffset + 1
                    })
                }
            }

            if persona.family == .startReturn {
                #expect(candidate.sessionIntents.allSatisfy {
                    $0.sessionClass == .race || $0.hardClass != .hardRun
                }, "Unknown continuity must keep beginner quality closed for \(persona.id)")
            }
        }
    }

    @Test func startReturnQualityRequiresTrainingEvidenceNotHealthSignals() throws {
        let persona = try #require(RunningPlannerTestFixtures.goldenPersonas.first {
            $0.id == "start.first-5k.12w"
        })
        let closedRequest = legacyRequest(persona, ordinal: 100)
        let legacy = LegacyRoadPolicyAdapter(catalog: RunningPlannerTestFixtures.catalog)
        let legacyCandidate = try legacyValue(legacy.evaluate(closedRequest))
        let qualityWeek = try #require(legacyCandidate.plan.weeks.first { week in
            legacyCandidate.sessionIntents.contains {
                $0.weekIndex == week.index && $0.sessionClass != .race && $0.hardClass == .hardRun
            }
        })
        let policy = StartReturnRoadPolicy(catalog: RunningPlannerTestFixtures.catalog)
        let closed = policy.sessionIntents(for: PolicyWeekContext(
            request: closedRequest,
            generatedPlan: legacyCandidate.plan,
            weekIndex: qualityWeek.index
        ))
        #expect(closed.allSatisfy { $0.sessionClass == .race || $0.hardClass != .hardRun })
        #expect(closed.contains { $0.workDose.intervalPrescription == "Run/walk 1:1" })

        let openState = qualifiedStartState(source: .momentumWorkout)
        #expect(RoadPolicySemantics.startReturnQualityGateIsOpen(openState))
        let openRequest = replacing(closedRequest, athleteState: openState)
        let open = policy.sessionIntents(for: PolicyWeekContext(
            request: openRequest,
            generatedPlan: legacyCandidate.plan,
            weekIndex: qualityWeek.index
        ))
        #expect(open.contains { $0.sessionClass != .race && $0.hardClass == .hardRun })

        let healthState = qualifiedStartState(source: .healthSignal)
        #expect(!RoadPolicySemantics.startReturnQualityGateIsOpen(healthState))
        let healthRequest = replacing(closedRequest, athleteState: healthState)
        let healthProjection = policy.sessionIntents(for: PolicyWeekContext(
            request: healthRequest,
            generatedPlan: legacyCandidate.plan,
            weekIndex: qualityWeek.index
        ))
        #expect(healthProjection.allSatisfy { $0.sessionClass == .race || $0.hardClass != .hardRun })
    }

    @Test func policiesOwnDistinctObjectivesAndTargetHierarchies() throws {
        var baseObjectives: [RunningPolicyID: String] = [:]
        for (ordinal, persona) in representatives.enumerated() {
            let candidate = try value(planner.evaluate(legacyRequest(persona, ordinal: 200 + ordinal)),
                                      persona: persona.id)
            let objective = try #require(candidate.blocks.first(where: { $0.phase == .base })?.objective)
            baseObjectives[candidate.selectedPolicyID] = objective
            for intent in candidate.sessionIntents {
                if intent.discipline == .strength {
                    #expect(intent.targetHierarchy.primary == .strengthPrescription)
                } else if intent.sessionClass == .race {
                    #expect(intent.targetHierarchy.primary == .completion)
                } else if intent.sessionClass == .easy || intent.sessionClass == .long {
                    #expect(intent.targetHierarchy.primary == .effort,
                            "\(candidate.selectedPolicyID.rawValue) \(intent.id) was \(intent.stimulus.rawValue)")
                } else if intent.stimulus == .threshold || intent.stimulus == .raceSpecific {
                    #expect([.pace, .intervalStructure].contains(intent.targetHierarchy.primary))
                } else if intent.stimulus == .vo2 || intent.stimulus == .speedNeuromuscular {
                    #expect(intent.targetHierarchy.primary == .intervalStructure)
                }
            }
        }
        #expect(baseObjectives.count == 4)
        #expect(Set(baseObjectives.values).count == 4)
    }

    @Test func unsupportedRoadBoundariesStopBeforeNumericGeneration() {
        let persona = RunningPlannerTestFixtures.goldenPersonas.first { $0.id == "road.10k-recreational" }!
        let request = legacyRequest(persona, ordinal: 300)
        let event = request.season.primaryEvent!
        let trailEvent = RunningSeasonEvent(
            id: event.id,
            name: event.name,
            date: event.date,
            distanceM: event.distanceM,
            durationS: event.durationS,
            priority: event.priority,
            surface: .trail
        )
        let trail = replacing(request, season: RunningSeason(
            id: request.season.id,
            name: request.season.name,
            status: request.season.status,
            primaryOutcome: request.season.primaryOutcome,
            motivations: request.season.motivations,
            events: [trailEvent]
        ))
        #expect(selectionConflict(RoadPolicyRouter.select(for: trail)) == .unsupportedSurface)

        let ultraGoal = RunningGoalContract(outcome: .finish, targetDistanceM: 50_000)
        let ultra = replacing(request, goal: ultraGoal)
        #expect(selectionConflict(RoadPolicyRouter.select(for: ultra)) == .unsupportedDistance)
    }

    @Test func seededShadowPreferenceMatrixRemainsDeterministicAndValid() throws {
        var generator = LCG(state: 0x5EA50A)
        let personas = RunningPlannerTestFixtures.goldenPersonas
        for caseIndex in 0..<128 {
            var persona = personas[Int(generator.next() % UInt64(personas.count))]
            let preferred = Set((0..<min(3, persona.inputs.daysPerWeek)).map { _ in
                Int(generator.next() % 7)
            })
            persona.inputs.preferredDayOffsets = preferred.sorted()
            let base = PlanningRequest.legacy(
                id: id(1_000 + caseIndex),
                inputs: persona.inputs,
                calibration: persona.calibration,
                name: "Seeded \(caseIndex)",
                generatedAt: RunningPlannerTestFixtures.startDate,
                startDate: RunningPlannerTestFixtures.startDate,
                calendar: RunningPlannerTestFixtures.calendar
            )
            let first = try planner.evaluate(base)
            switch first {
            case let .candidate(candidate):
                #expect(candidate.validation.isValid)
                #expect(candidate.plan.weeks.allSatisfy {
                    $0.sessions.count <= base.availability.trainingDaysPerWeek
                        && Set($0.sessions.map(\.dayOffset)).count == $0.sessions.count
                })
            case let .conflict(conflict):
                #expect(!conflict.conflicts.isEmpty)
            case .protectedSelfCoached:
                Issue.record("Seeded legacy request unexpectedly became self-coached at case \(caseIndex)")
            }

            // The scheduler's dedicated matrix replays every seed. Replaying a stable cross-section
            // here proves the full-season pipeline too without doubling 128 exhaustive seasons.
            guard caseIndex.isMultiple(of: 8) else { continue }
            let second = try planner.evaluate(base)
            switch (first, second) {
            case let (.candidate(left), .candidate(right)):
                #expect(left.semanticDigest == right.semanticDigest)
                #expect(left.scheduledWeeks == right.scheduledWeeks)
            case let (.conflict(left), .conflict(right)):
                #expect(left.conflicts == right.conflicts)
            case (.protectedSelfCoached, .protectedSelfCoached):
                break
            default:
                Issue.record("Non-deterministic shadow outcome at replayed case \(caseIndex)")
            }
        }
    }
}

private extension RoadPolicyShadowTests {
    enum FixtureError: Error { case expectedCandidate; case expectedLegacyCandidate }

    struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            return state
        }
    }

    var representatives: [RunningPlannerTestFixtures.GoldenPersona] {
        let names = [
            "start.first-5k.12w", "road.10k-recreational", "half.1h45", "marathon.4h",
        ]
        return names.compactMap { name in
            RunningPlannerTestFixtures.goldenPersonas.first { $0.id == name }
        }
    }

    func legacyRequest(_ persona: RunningPlannerTestFixtures.GoldenPersona,
                       ordinal: Int) -> PlanningRequest {
        PlanningRequest.legacy(
            id: id(ordinal + 1),
            inputs: persona.inputs,
            calibration: persona.calibration,
            name: "  \(persona.id) goal  ",
            generatedAt: RunningPlannerTestFixtures.startDate,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
    }

    func replacing(_ request: PlanningRequest,
                   goal: RunningGoalContract? = nil,
                   season: RunningSeason? = nil,
                   athleteState: RunningAthleteState? = nil) -> PlanningRequest {
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
            goal: goal ?? request.goal,
            season: season ?? request.season,
            availability: request.availability,
            athleteState: athleteState ?? request.athleteState,
            existingPlan: request.existingPlan,
            activeRestrictions: request.activeRestrictions,
            legacyBridge: request.legacyBridge
        )
    }

    func qualifiedStartState(source: RunningEvidenceSource) -> RunningAthleteState {
        let date = RunningPlannerTestFixtures.startDate
        return RunningAthleteState(
            continuity: RunningEvidence(
                value: RunningContinuity(activeWeeks: 2, observedWeeks: 2, currentConsecutiveWeeks: 2),
                source: source,
                observedAt: date,
                sampleCount: 2,
                confidence: .moderate
            ),
            toleranceBySessionClass: [
                .easy: RunningEvidence(
                    value: RunningToleranceObservation(
                        band: .developing,
                        completedExposureCount: 3,
                        typicalRecoveryS: RunningValueRange(lower: 24 * 3600, upper: 36 * 3600)
                    ),
                    source: source,
                    observedAt: date,
                    sampleCount: 3,
                    confidence: .moderate
                ),
            ]
        )
    }

    func value(_ result: ShadowRoadPlannerResult,
               persona: String) throws -> ShadowRoadPlanCandidate {
        guard case let .candidate(candidate) = result else {
            Issue.record("Expected a shadow candidate for \(persona), got \(result)")
            throw FixtureError.expectedCandidate
        }
        return candidate
    }

    func legacyValue(_ result: LegacyRoadAdapterResult) throws -> LegacyRoadPlanCandidate {
        guard case let .candidate(candidate) = result else {
            throw FixtureError.expectedLegacyCandidate
        }
        return candidate
    }

    func selectionConflict(_ result: RoadPolicySelectionResult) -> RunningPlanningConflictCode? {
        guard case let .conflict(conflict) = result else { return nil }
        return conflict.code
    }

    func policy(for family: RunningPlannerTestFixtures.Family) -> RunningPolicyID {
        switch family {
        case .startReturn: .startReturnRoadV1
        case .fiveKTenK: .road5K10KV1
        case .halfMarathon: .roadHalfMarathonV1
        case .marathon: .roadMarathonV1
        }
    }

    func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", value))!
    }
}
