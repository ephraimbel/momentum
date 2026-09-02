import Foundation

enum RoadPolicyAdjustmentCode: String, Codable, CaseIterable, Sendable {
    case qualityReplacedUntilContinuityGate
    case optionalEasyDoseRemovedForDayBudget
    case sessionMovedByOrderedScheduler
}

struct RoadPolicyAdjustment: Codable, Equatable, Sendable {
    let code: RoadPolicyAdjustmentCode
    let weekIndex: Int
    let intentID: String
    let fromDayOffset: Int?
    let toDayOffset: Int?
    let ruleIDs: [RunningRuleID]
    let detail: String
}

struct ShadowRoadPlanCandidate: Sendable {
    let requestID: UUID
    let seasonID: UUID
    let planName: String
    let selectedPolicyID: RunningPolicyID
    let policyVersion: Int
    let plannerVersion: String
    let rulesetID: String
    /// Final shadow value after policy projection, ordered scheduling, display snapping, and the
    /// second invariant pass. This value is never persisted by `ShadowRoadPlanner`.
    let plan: GeneratedPlan
    let semanticSnapshot: PlanSemanticSnapshot
    let semanticDigest: PlanSemanticDigest
    let legacySemanticDigest: PlanSemanticDigest
    let differenceFromExisting: PlanSemanticDiff?
    let feasibility: FeasibilityResult
    let validation: PlanValidationReport
    let blocks: [BlockIntent]
    let weeklyDoses: [WeeklyDoseEnvelope]
    let sessionIntents: [SessionIntent]
    let scheduledWeeks: [RunningScheduledWeek]
    let executionPrescriptions: [ExecutionPrescription]
    let adjustments: [RoadPolicyAdjustment]
    let carriedCompletedSessionIDs: [UUID]
    let trace: RunningDecisionTrace
}

enum ShadowRoadPlannerResult: Sendable {
    case candidate(ShadowRoadPlanCandidate)
    case protectedSelfCoached(LegacyRoadProtectedResult)
    case conflict(LegacyRoadConflictResult)
}

/// WP4 qualification pipeline. It uses the shipping generator only as a frozen numeric-dose seed,
/// then runs explicit policy semantics, ordered scheduling, final snapping, and validation. It has
/// no persistence dependency and cannot activate a plan.
struct ShadowRoadPlanner: Sendable {
    let catalog: [ExerciseCatalogItem]
    let registry: RunningRuleRegistry
    let scheduler: OrderedRunningScheduler

    init(catalog: [ExerciseCatalogItem],
         registry: RunningRuleRegistry = .legacyRoadV1,
         scheduler: OrderedRunningScheduler = OrderedRunningScheduler()) {
        self.catalog = catalog
        self.registry = registry
        self.scheduler = scheduler
    }

    func evaluate(_ request: PlanningRequest) throws -> ShadowRoadPlannerResult {
        let legacy = LegacyRoadPolicyAdapter(catalog: catalog, registry: registry)
        if request.existingPlan?.isSelfCoached == true,
           request.authority != .athleteRequestedCoaching {
            switch try legacy.evaluate(request) {
            case let .protectedSelfCoached(value): return .protectedSelfCoached(value)
            case let .conflict(value): return .conflict(value)
            case .candidate:
                return .conflict(conflictResult(
                    [RunningPlanningConflict(
                        .selfCoachedProtected,
                        field: "existingPlan.isSelfCoached",
                        detail: "Shadow planning cannot rewrite an athlete-owned plan."
                    )],
                    request: request,
                    policyID: nil
                ))
            }
        }

        let selectedPolicyID: RunningPolicyID
        switch RoadPolicyRouter.select(for: request) {
        case let .selected(value): selectedPolicyID = value
        case let .conflict(conflict):
            return .conflict(conflictResult([conflict], request: request, policyID: nil))
        }

        // Fixed calendar constraints and active restrictions belong to the new scheduler. Strip
        // only those fields from the temporary legacy dose request so the old adapter cannot reject
        // a capability that this pipeline now implements. The original request remains the source
        // for policy, scheduling, evidence, and trace decisions.
        let doseRequest = legacyDoseRequest(from: request)
        let legacyCandidate: LegacyRoadPlanCandidate
        switch try legacy.evaluate(doseRequest) {
        case let .candidate(value): legacyCandidate = value
        case let .protectedSelfCoached(value): return .protectedSelfCoached(value)
        case let .conflict(value): return .conflict(value)
        }
        guard legacyCandidate.selectedPolicyID == selectedPolicyID else {
            return .conflict(conflictResult(
                [RunningPlanningConflict(
                    .policyMismatch,
                    field: "policyID",
                    detail: "Explicit routing selected \(selectedPolicyID.rawValue), but the legacy dose bridge selected \(legacyCandidate.selectedPolicyID.rawValue)."
                )],
                request: request,
                policyID: selectedPolicyID
            ))
        }

        let policy = RoadPolicyRouter.policy(selectedPolicyID, catalog: catalog, registry: registry)
        let feasibility = policy.feasibility(for: doseRequest)
        guard feasibility.conflicts.isEmpty else {
            return .conflict(conflictResult(feasibility.conflicts, request: request, policyID: selectedPolicyID))
        }
        let blocks = RoadPolicySemantics.project(legacyCandidate.blocks, for: selectedPolicyID)

        var projectedByWeek: [Int: [SessionIntent]] = [:]
        var scheduledWeeks: [RunningScheduledWeek] = []
        var adjustments: [RoadPolicyAdjustment] = []
        for week in legacyCandidate.plan.weeks {
            let context = PolicyWeekContext(
                request: request,
                generatedPlan: legacyCandidate.plan,
                weekIndex: week.index
            )
            let original = legacyCandidate.sessionIntents.filter { $0.weekIndex == week.index }
            let projected = policy.sessionIntents(for: context)
            projectedByWeek[week.index] = projected
            adjustments.append(contentsOf: Self.policyAdjustments(
                original: original,
                projected: projected,
                weekIndex: week.index
            ))
            let weekStart = try Self.weekStart(index: week.index, request: request)
            switch scheduler.schedule(
                weekIndex: week.index,
                weekStart: weekStart,
                intents: projected,
                request: request
            ) {
            case let .scheduled(value):
                scheduledWeeks.append(value)
                adjustments.append(contentsOf: value.placements.compactMap { placement in
                    guard placement.originalDayOffset != placement.scheduledDayOffset else { return nil }
                    return RoadPolicyAdjustment(
                        code: .sessionMovedByOrderedScheduler,
                        weekIndex: week.index,
                        intentID: placement.intent.id,
                        fromDayOffset: placement.originalDayOffset,
                        toDayOffset: placement.scheduledDayOffset,
                        ruleIDs: [.calendarScheduling, .hardDaySpacing],
                        detail: "Moved after hard constraints and higher-order athlete preferences were applied."
                    )
                })
            case let .conflict(conflicts):
                return .conflict(conflictResult(
                    conflicts,
                    request: request,
                    policyID: selectedPolicyID,
                    appliedRules: [.calendarScheduling, .hardDaySpacing]
                ))
            }
        }

        let finalPlan = try Self.finalize(
            legacyPlan: legacyCandidate.plan,
            legacyIntents: legacyCandidate.sessionIntents,
            projectedByWeek: projectedByWeek,
            scheduledWeeks: scheduledWeeks,
            displayUnit: request.displayUnit
        )
        guard let bridge = request.legacyBridge,
              let calendar = try? request.calendar.value() else {
            return .conflict(conflictResult(
                [RunningPlanningConflict(
                    .missingLegacyBridge,
                    field: "legacyBridge",
                    detail: "The shadow numeric-dose bridge is required until new policy dose bounds are coach-qualified."
                )],
                request: request,
                policyID: selectedPolicyID
            ))
        }
        let validation = RoadPolicyFinalValidator.validate(
            finalPlan,
            intentsByWeek: projectedByWeek,
            schedules: scheduledWeeks,
            policyID: selectedPolicyID,
            inputs: bridge.inputs,
            calibration: bridge.calibration,
            request: request,
            calendar: calendar
        )
        guard validation.isValid else {
            let codes = validation.hardViolations.map(\.code.rawValue).joined(separator: ", ")
            return .conflict(conflictResult(
                [RunningPlanningConflict(
                    .validationFailed,
                    field: "candidate",
                    detail: "The final snapped shadow candidate failed invariant validation: \(codes).",
                    alternatives: ["Keep the current plan unchanged"]
                )],
                request: request,
                policyID: selectedPolicyID,
                validation: validation,
                appliedRules: [.displayRounding]
            ))
        }

        let snapshot = finalPlan.semanticSnapshot()
        let digest = try snapshot.digest()
        let difference = try request.existingPlan?.semanticPlan.map {
            try PlanSemanticDiffer.compare($0, snapshot)
        }
        let finalContexts = finalPlan.weeks.map {
            PolicyWeekContext(request: request, generatedPlan: finalPlan, weekIndex: $0.index)
        }
        let weeklyDoses = finalContexts.map(policy.weeklyDose)
        let intents = finalPlan.weeks.flatMap { projectedByWeek[$0.index] ?? [] }
        let prescriptions = Self.executionPrescriptions(
            request: request,
            plan: finalPlan,
            scheduledWeeks: scheduledWeeks
        )
        guard prescriptions.allSatisfy({ $0.validationIssues.isEmpty }) else {
            return .conflict(conflictResult(
                [RunningPlanningConflict(
                    .validationFailed,
                    field: "executionPrescriptions",
                    detail: "At least one phone/Watch execution payload is invalid; the shadow candidate was rejected."
                )],
                request: request,
                policyID: selectedPolicyID,
                validation: validation
            ))
        }

        let appliedRules = Set(legacyCandidate.trace.appliedRuleIDs)
            .union(blocks.flatMap(\.ruleIDs))
            .union(intents.flatMap(\.ruleIDs))
            .union(scheduledWeeks.flatMap(\.appliedRuleIDs))
            .union([.displayRounding])
        let orderedRules = appliedRules.sorted { $0.rawValue < $1.rawValue }
        guard orderedRules.allSatisfy({ registry[$0] != nil }) else {
            return .conflict(conflictResult(
                [RunningPlanningConflict(
                    .rulesetMismatch,
                    field: "decisionTrace.appliedRuleIDs",
                    detail: "The shadow trace references a rule absent from the compiled ruleset."
                )],
                request: request,
                policyID: selectedPolicyID
            ))
        }
        let hard = scheduledWeeks.reduce(into: legacyCandidate.trace.hardConstraints) {
            $0.formUnion($1.hardConstraints)
        }
        let relaxed = scheduledWeeks.reduce(into: Set<RunningRelaxedPreference>()) {
            $0.formUnion($1.relaxedPreferences)
        }
        var limitations = legacyCandidate.trace.evidenceLimitations
        if selectedPolicyID == .startReturnRoadV1 { limitations.remove(.noProgressionGate) }
        let trace = RunningDecisionTrace(
            id: "shadow:\(request.id.uuidString.lowercased()):candidate",
            requestID: request.id,
            status: .candidate,
            plannerVersion: request.plannerVersion,
            rulesetID: request.rulesetID,
            policyID: selectedPolicyID,
            appliedRuleIDs: orderedRules,
            hardConstraints: hard,
            relaxedPreferences: relaxed,
            evidence: request.athleteState.evidenceSummaries,
            evidenceLimitations: limitations,
            legacyExceptions: validation.legacyExceptions.map(\.code),
            validationCodes: [],
            headline: "Road policy shadow candidate validated",
            detail: "The event policy, ordered scheduler, final unit rounding, invariant gate, and shared execution payload agree. Numeric dose remains legacy-backed and this candidate cannot activate a plan."
        )
        return .candidate(ShadowRoadPlanCandidate(
            requestID: request.id,
            seasonID: request.season.id,
            planName: legacyCandidate.planName,
            selectedPolicyID: selectedPolicyID,
            policyVersion: policy.version,
            plannerVersion: request.plannerVersion,
            rulesetID: request.rulesetID,
            plan: finalPlan,
            semanticSnapshot: snapshot,
            semanticDigest: digest,
            legacySemanticDigest: legacyCandidate.semanticDigest,
            differenceFromExisting: difference,
            feasibility: feasibility,
            validation: validation,
            blocks: blocks,
            weeklyDoses: weeklyDoses,
            sessionIntents: intents,
            scheduledWeeks: scheduledWeeks,
            executionPrescriptions: prescriptions,
            adjustments: adjustments.sorted(by: Self.adjustmentOrder),
            carriedCompletedSessionIDs: legacyCandidate.carriedCompletedSessionIDs,
            trace: trace
        ))
    }
}

private extension ShadowRoadPlanner {
    static func weekStart(index: Int, request: PlanningRequest) throws -> Date {
        let calendar = try request.calendar.value()
        guard let date = calendar.date(byAdding: .day, value: index * 7,
                                       to: calendar.startOfDay(for: request.startDate)) else {
            throw RunningCalendarError.invalidIdentifier(request.calendar.identifier)
        }
        return date
    }

    func legacyDoseRequest(from request: PlanningRequest) -> PlanningRequest {
        let availability = RunningAvailability(
            trainingDaysPerWeek: request.availability.trainingDaysPerWeek,
            preferredWeekdays: [],
            preferredDayOffsets: request.availability.preferredDayOffsets,
            fixedDates: [],
            sessionTimeCeilingS: request.availability.sessionTimeCeilingS,
            equipment: request.availability.equipment,
            overrides: request.availability.overrides
        )
        return PlanningRequest(
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
            availability: availability,
            athleteState: request.athleteState,
            existingPlan: request.existingPlan,
            activeRestrictions: [],
            legacyBridge: request.legacyBridge
        )
    }

    func conflictResult(_ conflicts: [RunningPlanningConflict],
                        request: PlanningRequest,
                        policyID: RunningPolicyID?,
                        validation: PlanValidationReport? = nil,
                        appliedRules: Set<RunningRuleID> = []) -> LegacyRoadConflictResult {
        LegacyRoadConflictResult(
            conflicts: conflicts,
            trace: RunningDecisionTrace(
                id: "shadow:\(request.id.uuidString.lowercased()):conflict",
                requestID: request.id,
                status: .conflict,
                plannerVersion: request.plannerVersion,
                rulesetID: request.rulesetID,
                policyID: policyID,
                appliedRuleIDs: appliedRules.sorted { $0.rawValue < $1.rawValue },
                hardConstraints: [.supportedRoadPopulation, .onePrimaryOutcome, .validatedBeforeCommit],
                relaxedPreferences: [],
                evidence: request.athleteState.evidenceSummaries,
                evidenceLimitations: request.athleteState.evidenceSummaries.reduce(into: Set()) {
                    $0.formUnion($1.limitations)
                },
                legacyExceptions: validation?.legacyExceptions.map(\.code) ?? [],
                validationCodes: validation?.hardViolations.map(\.code) ?? [],
                headline: "Shadow plan not generated",
                detail: "The live plan remains untouched until every typed conflict is resolved."
            )
        )
    }

    static func policyAdjustments(original: [SessionIntent],
                                  projected: [SessionIntent],
                                  weekIndex: Int) -> [RoadPolicyAdjustment] {
        let byID = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
        var result: [RoadPolicyAdjustment] = []
        for intent in original {
            guard let replacement = byID[intent.id] else {
                result.append(RoadPolicyAdjustment(
                    code: .optionalEasyDoseRemovedForDayBudget,
                    weekIndex: weekIndex,
                    intentID: intent.id,
                    fromDayOffset: intent.dayOffset,
                    toDayOffset: nil,
                    ruleIDs: [.calendarScheduling, .qualityDose],
                    detail: "Removed the smallest optional easy session rather than exceed the athlete's chosen day budget."
                ))
                continue
            }
            if intent.hardClass == .hardRun && replacement.hardClass == .none {
                result.append(RoadPolicyAdjustment(
                    code: .qualityReplacedUntilContinuityGate,
                    weekIndex: weekIndex,
                    intentID: intent.id,
                    fromDayOffset: intent.dayOffset,
                    toDayOffset: replacement.dayOffset,
                    ruleIDs: [.returnProgression],
                    detail: "Replaced faster work with effort-first run/walk because continuity and response evidence are not yet sufficient."
                ))
            }
        }
        return result
    }

    static func finalize(legacyPlan: GeneratedPlan,
                         legacyIntents: [SessionIntent],
                         projectedByWeek: [Int: [SessionIntent]],
                         scheduledWeeks: [RunningScheduledWeek],
                         displayUnit: DistanceUnit) throws -> GeneratedPlan {
        let schedules = Dictionary(uniqueKeysWithValues: scheduledWeeks.map { ($0.weekIndex, $0) })
        var plan = legacyPlan
        for weekIndex in plan.weeks.indices {
            let weekNumber = plan.weeks[weekIndex].index
            let originals = legacyIntents.filter { $0.weekIndex == weekNumber }
            guard originals.count == plan.weeks[weekIndex].sessions.count,
                  let projected = projectedByWeek[weekNumber],
                  let schedule = schedules[weekNumber] else {
                throw ShadowRoadPlannerError.intentSessionMismatch(weekNumber)
            }
            let projectedByID = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
            let dayByID = Dictionary(uniqueKeysWithValues: schedule.placements.map {
                ($0.intent.id, $0.scheduledDayOffset)
            })
            var sessions: [GeneratedSession] = []
            for (index, original) in originals.enumerated() {
                guard let intent = projectedByID[original.id], let day = dayByID[original.id] else {
                    continue
                }
                var session = plan.weeks[weekIndex].sessions[index]
                session.dayOffset = day
                session.discipline = intent.discipline
                session.runType = intent.legacyRunType
                session.targetDistanceM = intent.workDose.distanceM
                session.targetDurationS = intent.workDose.durationS
                session.targetPaceSPerKm = intent.workDose.paceSPerKm
                session.intervals = intent.workDose.intervalPrescription
                session.isHardRun = intent.hardClass == .hardRun
                session.isHardLowerLift = intent.hardClass == .hardLowerBodyStrength
                session.rationale = intent.purpose
                if session.discipline != .strength {
                    session.strengthLabel = nil
                    session.strengthTargets = []
                    if let distance = session.targetDistanceM {
                        session.targetDistanceM = RunRounding.snap(
                            meters: distance,
                            unit: displayUnit,
                            isRace: session.runType == .race
                        )
                    }
                    if let pace = session.targetPaceSPerKm, let runType = session.runType {
                        session.targetPaceSPerKm = RunRounding.snapPace(
                            sPerKm: pace,
                            unit: displayUnit,
                            type: runType
                        )
                    }
                    if original.workDose.durationS == nil,
                       session.targetDurationS != nil,
                       let distance = session.targetDistanceM,
                       let pace = session.targetPaceSPerKm {
                        session.targetDurationS = distance / 1_000 * pace
                    }
                }
                sessions.append(session)
            }
            plan.weeks[weekIndex].sessions = sessions.sorted {
                $0.dayOffset == $1.dayOffset
                    ? ($0.runType?.rawValue ?? $0.discipline.rawValue) < ($1.runType?.rawValue ?? $1.discipline.rawValue)
                    : $0.dayOffset < $1.dayOffset
            }
        }
        return plan
    }

    static func executionPrescriptions(request: PlanningRequest,
                                       plan: GeneratedPlan,
                                       scheduledWeeks: [RunningScheduledWeek]) -> [ExecutionPrescription] {
        let planID = (request.existingPlan?.id ?? request.id).uuidString.lowercased()
        let scheduleByWeek = Dictionary(uniqueKeysWithValues: scheduledWeeks.map { ($0.weekIndex, $0) })
        var result: [ExecutionPrescription] = []
        for week in plan.weeks {
            let byDay = Dictionary(uniqueKeysWithValues: (scheduleByWeek[week.index]?.placements ?? []).map {
                ($0.scheduledDayOffset, $0.intent)
            })
            for session in week.sessions {
                let intent = byDay[session.dayOffset]
                guard let intent else { continue }
                let legacy = LegacyExecutionFields(
                    discipline: session.discipline,
                    runType: session.runType,
                    targetDistanceM: session.targetDistanceM,
                    targetDurationS: session.targetDurationS,
                    targetPaceSPerKm: session.targetPaceSPerKm,
                    intervalPrescription: session.intervals
                )
                result.append(ExecutionPrescriptionBuilder.build(
                    planID: planID,
                    sessionID: intent.id,
                    intent: intent,
                    legacy: legacy,
                    structuredWorkout: nil
                ))
            }
        }
        return result
    }

    static func adjustmentOrder(_ lhs: RoadPolicyAdjustment, _ rhs: RoadPolicyAdjustment) -> Bool {
        if lhs.weekIndex != rhs.weekIndex { return lhs.weekIndex < rhs.weekIndex }
        if lhs.intentID != rhs.intentID { return lhs.intentID < rhs.intentID }
        return lhs.code.rawValue < rhs.code.rawValue
    }
}

enum ShadowRoadPlannerError: Error, Equatable {
    case intentSessionMismatch(Int)
}

enum RoadPolicyFinalValidator {
    static func validate(_ plan: GeneratedPlan,
                         intentsByWeek: [Int: [SessionIntent]],
                         schedules: [RunningScheduledWeek],
                         policyID: RunningPolicyID,
                         inputs: PlanInputs,
                         calibration: CalibrationSeed,
                         request: PlanningRequest,
                         calendar: Calendar) -> PlanValidationReport {
        let legacy = LegacyPlanInvariantValidator.validate(
            plan,
            inputs: inputs,
            calibration: calibration,
            startDate: request.startDate,
            calendar: calendar
        )
        var issues = legacy.hardViolations.filter { issue in
            guard issue.code == .frequencyBudgetMismatch,
                  let weekIndex = issue.location.weekIndex,
                  let week = plan.weeks.first(where: { $0.index == weekIndex }) else { return true }
            // The new invariant is the athlete's explicit budget. The legacy podium shakeout
            // expectation is intentionally not carried forward.
            return week.sessions.count > request.availability.trainingDaysPerWeek
        }
        let scheduleIndexes = schedules.map(\.weekIndex)
        if scheduleIndexes != plan.weeks.map(\.index) {
            issues.append(PlanValidationIssue(
                code: .nonSequentialWeekIndex,
                location: .plan,
                detail: "Every generated week must pass through the ordered scheduler exactly once."
            ))
        }
        for week in plan.weeks {
            let intents = intentsByWeek[week.index] ?? []
            if intents.count != week.sessions.count {
                issues.append(PlanValidationIssue(
                    code: .frequencyBudgetMismatch,
                    location: PlanValidationLocation(weekIndex: week.index, dayOffset: nil),
                    detail: "Final session and intent counts disagree."
                ))
            }
            if policyID == .startReturnRoadV1,
               !RoadPolicySemantics.startReturnQualityGateIsOpen(request.athleteState),
               intents.contains(where: { $0.hardClass == .hardRun && $0.sessionClass != .race }) {
                issues.append(PlanValidationIssue(
                    code: .deloadContainsHardRun,
                    location: PlanValidationLocation(weekIndex: week.index, dayOffset: nil),
                    detail: "Start/return quality appeared before continuity and response gates opened."
                ))
            }
        }
        issues.sort {
            if $0.code != $1.code { return $0.code.rawValue < $1.code.rawValue }
            return ($0.location.weekIndex ?? -1, $0.location.dayOffset ?? -1)
                < ($1.location.weekIndex ?? -1, $1.location.dayOffset ?? -1)
        }
        var exceptions = legacy.legacyExceptions
        if policyID == .startReturnRoadV1 {
            exceptions.removeAll { $0.code == .startReturnContinuityGateUnavailable }
        }
        return PlanValidationReport(hardViolations: issues, legacyExceptions: exceptions)
    }
}
