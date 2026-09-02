import Foundation

struct LegacyRoadPlanCandidate: Sendable {
    let requestID: UUID
    let seasonID: UUID
    let planName: String
    let selectedPolicyID: RunningPolicyID
    let plannerVersion: String
    let rulesetID: String
    let plan: GeneratedPlan
    let semanticSnapshot: PlanSemanticSnapshot
    let semanticDigest: PlanSemanticDigest
    let differenceFromExisting: PlanSemanticDiff?
    let validation: PlanValidationReport
    let blocks: [BlockIntent]
    let weeklyDoses: [WeeklyDoseEnvelope]
    let sessionIntents: [SessionIntent]
    let carriedCompletedSessionIDs: [UUID]
    let trace: RunningDecisionTrace
}

struct LegacyRoadProtectedResult: Codable, Equatable, Sendable {
    let existingPlanID: UUID
    let planName: String
    let trace: RunningDecisionTrace
}

struct LegacyRoadConflictResult: Codable, Equatable, Sendable {
    let conflicts: [RunningPlanningConflict]
    let trace: RunningDecisionTrace
}

enum LegacyRoadAdapterResult: Sendable {
    case candidate(LegacyRoadPlanCandidate)
    case protectedSelfCoached(LegacyRoadProtectedResult)
    case conflict(LegacyRoadConflictResult)
}

/// Stage-B bridge around the shipping deterministic generator. It accepts and returns values only,
/// cannot read Health or SwiftData, and is not wired into production generation.
struct LegacyRoadPolicyAdapter: RunningPolicy {
    let id: RunningPolicyID = .legacyRoadV1
    let version: Int = 1
    let catalog: [ExerciseCatalogItem]
    let registry: RunningRuleRegistry

    init(catalog: [ExerciseCatalogItem],
         registry: RunningRuleRegistry = .legacyRoadV1) {
        self.catalog = catalog
        self.registry = registry
    }

    func evaluate(_ request: PlanningRequest) throws -> LegacyRoadAdapterResult {
        if let existing = request.existingPlan,
           existing.isSelfCoached,
           request.authority != .athleteRequestedCoaching {
            let trace = RunningDecisionTrace(
                id: traceID(request, status: .protected),
                requestID: request.id,
                status: .protected,
                plannerVersion: request.plannerVersion,
                rulesetID: request.rulesetID,
                policyID: nil,
                appliedRuleIDs: [.selfCoachedBoundary],
                hardConstraints: [.selfCoachedOwnership],
                relaxedPreferences: [],
                evidence: request.athleteState.evidenceSummaries,
                evidenceLimitations: evidenceLimitations(request),
                legacyExceptions: [],
                validationCodes: [],
                headline: "Self-coached plan protected",
                detail: "Automatic and shadow planning cannot rewrite athlete-owned targets."
            )
            return .protectedSelfCoached(LegacyRoadProtectedResult(
                existingPlanID: existing.id,
                planName: existing.name,
                trace: trace
            ))
        }

        let initialConflicts = conflicts(for: request)
        if !initialConflicts.isEmpty {
            return .conflict(conflictResult(initialConflicts, request: request))
        }
        guard let bridge = request.legacyBridge else {
            let conflict = RunningPlanningConflict(
                .missingLegacyBridge,
                field: "legacyBridge",
                detail: "The Stage-B legacy adapter requires an explicit legacy value bridge."
            )
            return .conflict(conflictResult([conflict], request: request))
        }

        let calendar: Calendar
        do {
            calendar = try request.calendar.value()
        } catch {
            let conflict = RunningPlanningConflict(
                .invalidCalendar,
                field: "calendar",
                detail: "The injected calendar cannot be reconstructed deterministically."
            )
            return .conflict(conflictResult([conflict], request: request))
        }
        let selectedPolicy = Self.selectPolicy(inputs: bridge.inputs)
        let plan = PlanEngine.generate(
            profile: bridge.inputs,
            catalog: catalog,
            calibration: bridge.calibration,
            startDate: request.startDate,
            calendar: calendar
        )
        let validation = LegacyPlanInvariantValidator.validate(
            plan,
            inputs: bridge.inputs,
            calibration: bridge.calibration,
            startDate: request.startDate,
            calendar: calendar
        )
        guard validation.isValid else {
            let codes = validation.hardViolations.map(\.code).map(\.rawValue).joined(separator: ", ")
            let conflict = RunningPlanningConflict(
                .validationFailed,
                field: "candidate",
                detail: "The legacy candidate failed final invariant validation: \(codes).",
                alternatives: ["Keep the current plan unchanged"]
            )
            return .conflict(conflictResult(
                [conflict], request: request,
                policyID: selectedPolicy,
                validation: validation
            ))
        }

        let snapshot = plan.semanticSnapshot()
        let digest = try snapshot.digest()
        let difference = try request.existingPlan?.semanticPlan.map {
            try PlanSemanticDiffer.compare($0, snapshot)
        }
        let blocks = Self.blocks(plan, requestID: request.id)
        let weekContexts = plan.weeks.map {
            PolicyWeekContext(request: request, generatedPlan: plan, weekIndex: $0.index)
        }
        let doses = weekContexts.map(weeklyDose)
        let intents = weekContexts.flatMap(sessionIntents)
        let ruleIDs = appliedRuleIDs(
            inputs: bridge.inputs,
            plan: plan,
            selectedPolicy: selectedPolicy
        )
        let limitations = evidenceLimitations(request).union(
            validation.legacyExceptions.flatMap(Self.limitations(for:))
        )
        let unknownRules = ruleIDs.filter { registry[$0] == nil }
        if !unknownRules.isEmpty {
            let conflict = RunningPlanningConflict(
                .rulesetMismatch,
                field: "decisionTrace.appliedRuleIDs",
                detail: "The decision trace references rules absent from the compiled ruleset."
            )
            return .conflict(conflictResult([conflict], request: request, policyID: selectedPolicy))
        }
        let trace = RunningDecisionTrace(
            id: traceID(request, status: .candidate),
            requestID: request.id,
            status: .candidate,
            plannerVersion: request.plannerVersion,
            rulesetID: request.rulesetID,
            policyID: selectedPolicy,
            appliedRuleIDs: ruleIDs,
            hardConstraints: hardConstraints(request: request, inputs: bridge.inputs),
            relaxedPreferences: relaxedPreferences(bridge.inputs),
            evidence: request.athleteState.evidenceSummaries,
            evidenceLimitations: limitations,
            legacyExceptions: validation.legacyExceptions.map(\.code).sorted { $0.rawValue < $1.rawValue },
            validationCodes: validation.hardViolations.map(\.code).sorted { $0.rawValue < $1.rawValue },
            headline: "Legacy plan reproduced",
            detail: "The candidate is semantically equivalent to the shipping deterministic planner and remains read-only in Stage B."
        )
        let proposedName = request.season.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let planName = proposedName.isEmpty ? (request.existingPlan?.name ?? "") : proposedName

        return .candidate(LegacyRoadPlanCandidate(
            requestID: request.id,
            seasonID: request.season.id,
            planName: planName,
            selectedPolicyID: selectedPolicy,
            plannerVersion: request.plannerVersion,
            rulesetID: request.rulesetID,
            plan: plan,
            semanticSnapshot: snapshot,
            semanticDigest: digest,
            differenceFromExisting: difference,
            validation: validation,
            blocks: blocks,
            weeklyDoses: doses,
            sessionIntents: intents,
            carriedCompletedSessionIDs: Self.completedCarryoverIDs(
                from: request.existingPlan,
                startDate: request.startDate,
                calendar: calendar
            ),
            trace: trace
        ))
    }

    // MARK: RunningPolicy

    func feasibility(for request: PlanningRequest) -> FeasibilityResult {
        let requestConflicts = conflicts(for: request)
        guard requestConflicts.isEmpty, let bridge = request.legacyBridge,
              let calendar = try? request.calendar.value() else {
            return FeasibilityResult(
                verdict: .unsupported,
                weeksAvailable: nil,
                weeksNeeded: nil,
                recommendedIntensity: nil,
                realisticFinishS: nil,
                weeklyCapShortfallM: nil,
                conflicts: requestConflicts.isEmpty
                    ? [RunningPlanningConflict(.invalidCalendar, field: "calendar",
                                                detail: "Calendar configuration is invalid.")]
                    : requestConflicts,
                headline: "Plan needs attention",
                detail: "Resolve the typed planning conflicts before generation.",
                options: []
            )
        }
        let inputs = bridge.inputs
        let p5k = bridge.calibration.recentRun.map {
            PlanEngine.riegelP5k(distanceM: $0.distanceM, timeS: $0.timeS)
        } ?? bridge.calibration.estimatedP5kSPerKm
        let currentRaceTime: Double? = {
            guard let distance = inputs.raceDistanceM,
                  let recent = bridge.calibration.recentRun,
                  abs(recent.distanceM - distance) < 100 else { return nil }
            return recent.timeS
        }()
        let days = Self.legacyRunDays(inputs)
        let weeks = PlanEngine.weeksToRace(
            startDate: request.startDate,
            raceDate: inputs.raceDate,
            calendar: calendar
        ) ?? 999
        let legacy = PlanFeasibility.assess(
            raceDistanceM: inputs.raceDistanceM,
            goalFinishTimeS: inputs.goalFinishTimeS,
            currentP5kSPerKm: p5k,
            currentWeeklyVolumeM: inputs.currentWeeklyVolumeM ?? 0,
            weeksAvailable: weeks,
            experience: inputs.runningExperience,
            injuryProne: !inputs.injuryHistory.isEmpty,
            daysPerWeek: days,
            intensity: inputs.intensity,
            currentRaceTimeS: currentRaceTime,
            targetWeeklyVolumeM: inputs.targetWeeklyVolumeM
        )
        let verdict: RunningFeasibilityVerdict = switch legacy.verdict {
        case .onTrack: .onTrack
        case .tight: .tight
        case .tooShort: .tooShort
        case .noRace: .noRace
        }
        return FeasibilityResult(
            verdict: verdict,
            weeksAvailable: legacy.verdict == .noRace ? nil : legacy.weeksAvailable,
            weeksNeeded: legacy.verdict == .noRace ? nil : legacy.weeksNeeded,
            recommendedIntensity: legacy.recommended,
            realisticFinishS: legacy.realisticFinishS,
            weeklyCapShortfallM: legacy.weeklyCapShortfallM,
            conflicts: [],
            headline: legacy.headline,
            detail: legacy.detail,
            options: legacy.options
        )
    }

    func blockMap(for request: PlanningRequest) -> [BlockIntent] {
        guard let plan = generatedPlan(for: request) else { return [] }
        return Self.blocks(plan, requestID: request.id)
    }

    func weeklyDose(for context: PolicyWeekContext) -> WeeklyDoseEnvelope {
        guard let week = context.generatedPlan.weeks.first(where: { $0.index == context.weekIndex }) else {
            return WeeklyDoseEnvelope(
                weekIndex: context.weekIndex,
                phase: .base,
                trainingDistanceM: nil,
                trainingDurationS: nil,
                sessionCount: RunningValueRange(lower: 0, upper: 0),
                longRunDistanceM: nil,
                qualitySessionCount: RunningValueRange(lower: 0, upper: 0),
                strengthSessionCount: RunningValueRange(lower: 0, upper: 0)
            )
        }
        let endurance = week.sessions.filter { $0.discipline != .strength && $0.runType != .race }
        let distance = endurance.compactMap(\.targetDistanceM).reduce(0, +)
        let calculatedDurations = endurance.compactMap { session -> Double? in
            if let duration = session.targetDurationS { return duration }
            guard let distance = session.targetDistanceM, let pace = session.targetPaceSPerKm else { return nil }
            return distance / 1_000 * pace
        }
        let longDistance = week.sessions.filter {
            $0.runType == .long || $0.runType == .progression
        }.compactMap(\.targetDistanceM).max()
        return WeeklyDoseEnvelope(
            weekIndex: week.index,
            phase: week.phase,
            trainingDistanceM: endurance.isEmpty ? nil : Self.exact(distance),
            trainingDurationS: calculatedDurations.count == endurance.count && !endurance.isEmpty
                ? Self.exact(calculatedDurations.reduce(0, +)) : nil,
            sessionCount: Self.exact(Double(week.sessions.count)),
            longRunDistanceM: longDistance.map(Self.exact),
            qualitySessionCount: Self.exact(Double(week.sessions.filter(\.isHardRun).count)),
            strengthSessionCount: Self.exact(Double(week.sessions.filter { $0.discipline == .strength }.count))
        )
    }

    func sessionIntents(for context: PolicyWeekContext) -> [SessionIntent] {
        guard let week = context.generatedPlan.weeks.first(where: { $0.index == context.weekIndex }) else {
            return []
        }
        var occurrences: [Int: Int] = [:]
        return week.sessions.map { session in
            let occurrence = occurrences[session.dayOffset, default: 0]
            occurrences[session.dayOffset] = occurrence + 1
            return Self.intent(
                session,
                week: week,
                occurrence: occurrence,
                request: context.request
            )
        }
    }

    func exitDecision(for context: BlockExitContext) -> BlockExitDecision {
        let complete = context.plannedSessionCount > 0
            && context.completedSessionCount >= context.plannedSessionCount
        return BlockExitDecision(
            state: complete ? .advance : .hold,
            reasons: [complete
                ? "Legacy blocks advance on calendar/completion only."
                : "The legacy adapter has no evidence-qualified block exit gate."],
            ruleIDs: [.returnProgression],
            limitations: [.noProgressionGate, .legacyAggregate]
        )
    }

    // MARK: Request boundary

    private func conflicts(for request: PlanningRequest) -> [RunningPlanningConflict] {
        var result: [RunningPlanningConflict] = []
        guard request.rulesetID == registry.rulesetID else {
            return [RunningPlanningConflict(
                .rulesetMismatch,
                field: "rulesetID",
                detail: "The requested ruleset is not the adapter's complete compiled ruleset."
            )]
        }
        if !registry.isComplete {
            result.append(RunningPlanningConflict(
                .rulesetMismatch,
                field: "registry",
                detail: "The compiled rule registry is incomplete or invalid."
            ))
        }
        guard let bridge = request.legacyBridge else {
            result.append(RunningPlanningConflict(
                .missingLegacyBridge,
                field: "legacyBridge",
                detail: "Legacy inputs and calibration are required for parity evaluation."
            ))
            return result
        }
        let inputs = bridge.inputs
        result.append(contentsOf: bridgeConsistencyConflicts(
            request: request,
            inputs: inputs,
            calibration: bridge.calibration
        ))
        if !inputs.disciplines.contains(.running)
            || inputs.disciplines.contains(where: { $0 != .running && $0 != .strength }) {
            result.append(RunningPlanningConflict(
                .unsupportedDiscipline,
                field: "disciplines",
                detail: "Release-1 road policies support running with optional runner-strength only."
            ))
        }
        if !(1...7).contains(inputs.daysPerWeek) {
            result.append(RunningPlanningConflict(
                .invalidAvailability,
                field: "availability.trainingDaysPerWeek",
                detail: "Training availability must be between one and seven days."
            ))
        }
        if inputs.intensity == .podium && Self.legacyRunDays(inputs) < PlanIntensity.podium.floorDays {
            result.append(RunningPlanningConflict(
                .intensityRequiresMoreDays,
                field: "availability.trainingDaysPerWeek",
                detail: "Podium structure requires at least five running days.",
                alternatives: ["Add running days", "Choose Aggressive"]
            ))
        }
        if inputs.goal == .raceDistance, (inputs.raceDistanceM ?? 0) <= 0 {
            result.append(RunningPlanningConflict(
                .missingRaceDistance,
                field: "goal.targetDistanceM",
                detail: "A race outcome requires a positive target distance."
            ))
        }
        if let distance = inputs.raceDistanceM,
           !distance.isFinite || distance <= 0 || distance > RaceDistance.marathon.meters + 1 {
            result.append(RunningPlanningConflict(
                .unsupportedDistance,
                field: "goal.targetDistanceM",
                detail: "The Release-1 road-core boundary supports positive distances through the marathon."
            ))
        }
        if let goalDistance = request.goal.targetDistanceM,
           let legacyDistance = inputs.raceDistanceM,
           abs(goalDistance - legacyDistance) > 0.01 {
            result.append(RunningPlanningConflict(
                .goalMismatch,
                field: "goal.targetDistanceM",
                detail: "The domain goal and legacy bridge disagree on target distance."
            ))
        }
        for issue in request.season.validationIssues {
            switch issue.code {
            case .multiplePrimaryEvents:
                result.append(RunningPlanningConflict(
                    .multiplePrimaryEvents,
                    field: "season.events",
                    detail: "A season may have only one planned A event."
                ))
            case .missingPrimaryEvent:
                result.append(RunningPlanningConflict(
                    .missingPrimaryEvent,
                    field: "season.events",
                    detail: "This outcome requires a planned A event."
                ))
            default:
                result.append(RunningPlanningConflict(
                    .goalMismatch,
                    field: "season.events",
                    detail: "The season contains invalid event values."
                ))
            }
        }
        if let event = request.season.primaryEvent {
            if event.surface != .road {
                result.append(RunningPlanningConflict(
                    .unsupportedSurface,
                    field: "season.primaryEvent.surface",
                    detail: "The legacy road adapter does not substitute road training for another surface policy."
                ))
            }
            let startDay = (try? request.calendar.value().startOfDay(for: request.startDate))
                ?? request.startDate
            if event.date < startDay {
                result.append(RunningPlanningConflict(
                    .primaryEventInPast,
                    field: "season.primaryEvent.date",
                    detail: "Choose a future event or an undated base-building outcome."
                ))
            }
        }
        if let raceDate = inputs.raceDate {
            let startDay = (try? request.calendar.value().startOfDay(for: request.startDate))
                ?? request.startDate
            if raceDate < startDay {
                result.append(RunningPlanningConflict(
                    .primaryEventInPast,
                    field: "legacyBridge.inputs.raceDate",
                    detail: "The legacy race date is in the past and cannot be silently clamped."
                ))
            }
        }
        if !request.activeRestrictions.isEmpty {
            result.append(RunningPlanningConflict(
                .activeRestrictionUnsupported,
                field: "activeRestrictions",
                detail: "The legacy generator cannot prove that it honors active safety restrictions.",
                alternatives: ["Keep the current plan unchanged"]
            ))
        }
        return Self.unique(result)
    }

    /// The Stage-B request intentionally carries both the new domain contract and a temporary
    /// legacy value bridge. A candidate is valid only when every duplicated decision input agrees;
    /// otherwise the old generator could silently ignore the athlete's newest edit.
    private func bridgeConsistencyConflicts(request: PlanningRequest,
                                            inputs: PlanInputs,
                                            calibration: CalibrationSeed)
        -> [RunningPlanningConflict] {
        var result: [RunningPlanningConflict] = []

        func add(_ code: RunningPlanningConflictCode,
                 _ field: String,
                 _ detail: String) {
            result.append(RunningPlanningConflict(code, field: field, detail: detail))
        }

        if request.displayUnit != inputs.distanceUnit {
            add(.displayUnitMismatch, "displayUnit",
                "The domain display unit and legacy prescription unit disagree.")
        }

        let availability = request.availability
        if availability.trainingDaysPerWeek != inputs.daysPerWeek {
            add(.availabilityMismatch, "availability.trainingDaysPerWeek",
                "The domain and legacy training-day budgets disagree.")
        }
        if availability.preferredDayOffsets != Set(inputs.preferredDayOffsets) {
            add(.availabilityMismatch, "availability.preferredDayOffsets",
                "The domain and legacy preferred training days disagree.")
        }
        if !availability.preferredWeekdays.isEmpty || !availability.fixedDates.isEmpty {
            add(.unsupportedAvailabilityConstraint, "availability.fixedDates",
                "The legacy planner cannot prove that it honors calendar weekdays, travel, or fixed-date constraints.")
        }
        if availability.preferredWeekdays.contains(where: { !(1...7).contains($0) })
            || availability.preferredDayOffsets.contains(where: { !(0...6).contains($0) })
            || inputs.preferredDayOffsets.contains(where: { !(0...6).contains($0) })
            || inputs.avoidDayOffsets.contains(where: { !(0...6).contains($0) }) {
            add(.invalidAvailability, "availability.trainingDays",
                "Calendar weekdays must be 1 through 7 and plan-day offsets must be 0 through 6.")
        }
        let expectedCeiling = Double(inputs.sessionMinutes) * 60
        if inputs.sessionMinutes <= 0
            || availability.sessionTimeCeilingS == nil
            || !Self.sameNumber(availability.sessionTimeCeilingS, expectedCeiling, tolerance: 0.5) {
            add(.availabilityMismatch, "availability.sessionTimeCeilingS",
                "The domain and legacy session-time budgets disagree or are invalid.")
        }
        if availability.equipment != inputs.equipment {
            add(.preferenceMismatch, "availability.equipment",
                "The domain and legacy equipment choices disagree.")
        }
        let overrides = availability.overrides
        if overrides.intensity != inputs.intensity
            || !Self.sameNumber(overrides.targetWeeklyDistanceM, inputs.targetWeeklyVolumeM)
            || overrides.hybridPriority != inputs.hybridPriority
            || overrides.strengthSplit != inputs.strengthSplit
            || overrides.muscleFocus != Set(inputs.muscleFocus) {
            add(.preferenceMismatch, "availability.overrides",
                "The domain and legacy intensity, volume, or runner-strength preferences disagree.")
        }

        let expectedOutcome: RunningPrimaryOutcome = {
            if inputs.goal == .raceDistance {
                return inputs.goalFinishTimeS == nil ? .finish : .targetTime
            }
            return inputs.runningExperience == .new ? .returnToRunning : .buildBase
        }()
        if request.goal.outcome != expectedOutcome
            || request.season.primaryOutcome != request.goal.outcome {
            add(.goalMismatch, "goal.outcome",
                "The season, domain goal, and legacy goal describe different outcomes.")
        }
        if !Self.sameNumber(request.goal.targetDistanceM, inputs.raceDistanceM) {
            add(.goalMismatch, "goal.targetDistanceM",
                "The domain goal and legacy bridge disagree on target distance.")
        }
        if !Self.sameNumber(request.goal.targetDurationS, inputs.goalFinishTimeS) {
            add(.goalMismatch, "goal.targetDurationS",
                "The domain goal and legacy bridge disagree on target time.")
        }
        for (field, value) in [
            ("goal.targetDistanceM", request.goal.targetDistanceM),
            ("goal.targetDurationS", request.goal.targetDurationS),
        ] where value.map({ !$0.isFinite || $0 <= 0 }) == true {
            add(.goalMismatch, field, "Goal values must be finite and positive SI values.")
        }

        let primaryEvent = request.season.primaryEvent
        switch (inputs.raceDate, primaryEvent) {
        case let (raceDate?, event?):
            if abs(event.date.timeIntervalSince(raceDate)) > 0.5
                || !Self.sameNumber(event.distanceM, inputs.raceDistanceM)
                || !Self.sameNumber(event.durationS, inputs.goalFinishTimeS) {
                add(.eventMismatch, "season.primaryEvent",
                    "The primary event and legacy bridge disagree on date, distance, or target time.")
            }
        case (nil, nil):
            break
        case (.some, nil), (nil, .some):
            add(.eventMismatch, "season.primaryEvent",
                "The domain and legacy bridge disagree on whether a dated primary event exists.")
        }
        if request.season.events.contains(where: { $0.id != primaryEvent?.id }) {
            add(.unsupportedEventConstraint, "season.events",
                "The legacy planner cannot schedule tune-up, secondary, withdrawn, or cancelled events.")
        }
        if let event = primaryEvent,
           event.ascentM != nil || event.descentM != nil
            || event.altitude != .unknown || event.technicality != .unknown || event.climate != .unknown {
            add(.unsupportedEventConstraint, "season.primaryEvent.courseDemands",
                "The legacy planner cannot prove that it honors elevation, altitude, technicality, or climate demands.")
        }

        let nonNegativeAggregates = [inputs.currentWeeklyVolumeM, inputs.longestRunM]
            .compactMap { $0 }
        let positiveAggregates = [inputs.goalFinishTimeS, inputs.targetWeeklyVolumeM]
            .compactMap { $0 }
        let invalidCalibration = calibration.recentRun.map {
            !$0.distanceM.isFinite || $0.distanceM <= 0 || !$0.timeS.isFinite || $0.timeS <= 0
        } == true
            || calibration.estimatedP5kSPerKm.map { !$0.isFinite || $0 <= 0 } == true
            || calibration.lifts.values.contains(where: { !$0.isFinite || $0 <= 0 })
        if nonNegativeAggregates.contains(where: { !$0.isFinite || $0 < 0 })
            || positiveAggregates.contains(where: { !$0.isFinite || $0 <= 0 })
            || inputs.postRaceRecoveryWeeks < 0
            || inputs.age.map({ $0 < 18 || $0 > 120 }) == true
            || invalidCalibration {
            add(.invalidLegacyInput, "legacyBridge",
                "Legacy aggregate and calibration values must be finite, supported, and physically valid.")
        }
        return result
    }

    private func generatedPlan(for request: PlanningRequest) -> GeneratedPlan? {
        guard conflicts(for: request).isEmpty,
              let bridge = request.legacyBridge,
              let calendar = try? request.calendar.value() else { return nil }
        return PlanEngine.generate(
            profile: bridge.inputs,
            catalog: catalog,
            calibration: bridge.calibration,
            startDate: request.startDate,
            calendar: calendar
        )
    }

    private func conflictResult(_ conflicts: [RunningPlanningConflict],
                                request: PlanningRequest,
                                policyID: RunningPolicyID? = nil,
                                validation: PlanValidationReport? = nil) -> LegacyRoadConflictResult {
        LegacyRoadConflictResult(
            conflicts: conflicts,
            trace: RunningDecisionTrace(
                id: traceID(request, status: .conflict),
                requestID: request.id,
                status: .conflict,
                plannerVersion: request.plannerVersion,
                rulesetID: request.rulesetID,
                policyID: policyID,
                appliedRuleIDs: policyID == nil ? [] : [.feasibility],
                hardConstraints: [.supportedRoadPopulation, .onePrimaryOutcome, .validatedBeforeCommit],
                relaxedPreferences: [],
                evidence: request.athleteState.evidenceSummaries,
                evidenceLimitations: evidenceLimitations(request),
                legacyExceptions: validation?.legacyExceptions.map(\.code) ?? [],
                validationCodes: validation?.hardViolations.map(\.code) ?? [],
                headline: "Plan not generated",
                detail: "The current plan remains untouched until every typed conflict is resolved."
            )
        )
    }

    private func evidenceLimitations(_ request: PlanningRequest) -> Set<RunningEvidenceLimitation> {
        request.athleteState.evidenceSummaries.reduce(into: Set([.legacyAggregate])) {
            $0.formUnion($1.limitations)
        }
    }

    private func appliedRuleIDs(inputs: PlanInputs,
                                plan: GeneratedPlan,
                                selectedPolicy: RunningPolicyID) -> [RunningRuleID] {
        var ids: Set<RunningRuleID> = [
            .feasibility, .paceCalibration, .racePrediction, .weeklyVolumeProgression, .peakVolume,
            .longRunDose, .qualityDose, .deloadCadence, .loadGovernor, .hardDaySpacing,
            .calendarScheduling, .displayRounding,
        ]
        if inputs.raceDate != nil { ids.formUnion([.taperShape, .raceTerminal]) }
        if inputs.runningExperience == .new { ids.insert(.returnProgression) }
        if inputs.disciplines.contains(.strength) { ids.insert(.strengthSupport) }
        if !inputs.injuryHistory.isEmpty { ids.insert(.injuryHistory) }
        if plan.weeks.contains(where: { $0.sessions.contains(where: { $0.isHardRun }) }) {
            ids.insert(.intensityDistribution)
        }
        // Keep policy selection visible even though the legacy umbrella owns execution.
        _ = selectedPolicy
        return ids.sorted { $0.rawValue < $1.rawValue }
    }

    private func hardConstraints(request: PlanningRequest,
                                 inputs: PlanInputs) -> Set<RunningHardConstraint> {
        var result: Set<RunningHardConstraint> = [
            .supportedRoadPopulation, .onePrimaryOutcome, .availabilityBudget,
            .reductionOnlyLoadGuard, .lowerStrengthRecoverySpacing, .validatedBeforeCommit,
        ]
        if inputs.raceDate != nil { result.insert(.noTrainingAfterTerminalRace) }
        if !request.activeRestrictions.isEmpty { result.insert(.activeRestriction) }
        if request.existingPlan?.isSelfCoached == true { result.insert(.selfCoachedOwnership) }
        return result
    }

    private func relaxedPreferences(_ inputs: PlanInputs) -> Set<RunningRelaxedPreference> {
        var result: Set<RunningRelaxedPreference> = []
        if !inputs.preferredDayOffsets.isEmpty { result.insert(.preferredWeekday) }
        if !inputs.avoidDayOffsets.isEmpty { result.insert(.learnedAvoidWeekday) }
        if inputs.intensity != .balanced { result.insert(.requestedIntensityTier) }
        if inputs.strengthSplit != .coach { result.insert(.requestedStrengthSplit) }
        if inputs.sessionMinutes > 0 { result.insert(.sessionTimeCeilingForLongRun) }
        return result
    }

    // MARK: Deterministic mappings

    static func selectPolicy(inputs: PlanInputs) -> RunningPolicyID {
        if inputs.runningExperience == .new { return .startReturnRoadV1 }
        guard let distance = inputs.raceDistanceM, distance > 0 else { return .startReturnRoadV1 }
        if distance <= 10_000 + 1 { return .road5K10KV1 }
        if distance <= RaceDistance.half.meters + 1 { return .roadHalfMarathonV1 }
        return .roadMarathonV1
    }

    static func blocks(_ plan: GeneratedPlan, requestID: UUID) -> [BlockIntent] {
        guard let first = plan.weeks.first else { return [] }
        var result: [BlockIntent] = []
        var phase = first.phase
        var start = first.index

        func append(through end: Int, ordinal: Int) {
            let objective: String = switch phase {
            case .base: "Establish repeatable easy volume"
            case .build: "Progress event-relevant endurance and quality"
            case .peak: "Hold the highest event-specific training load"
            case .recovery: "Absorb the preceding training load"
            case .taper: "Reduce volume while retaining race-specific touch"
            }
            result.append(BlockIntent(
                id: "legacy:\(requestID.uuidString.lowercased()):block:\(ordinal)",
                phase: phase,
                firstWeekIndex: start,
                lastWeekIndex: end,
                objective: objective,
                ruleIDs: phase == .taper ? [.taperShape] : phase == .recovery ? [.deloadCadence] : [.weeklyVolumeProgression]
            ))
        }

        for week in plan.weeks.dropFirst() where week.phase != phase {
            append(through: week.index - 1, ordinal: result.count)
            phase = week.phase
            start = week.index
        }
        append(through: plan.weeks.last?.index ?? start, ordinal: result.count)
        return result
    }

    static func intent(_ session: GeneratedSession,
                       week: GeneratedWeek,
                       occurrence: Int,
                       request: PlanningRequest) -> SessionIntent {
        let stimulus = stimulus(session)
        let sessionClass = sessionClass(session)
        let hierarchy = targetHierarchy(session)
        var rules: Set<RunningRuleID> = [.calendarScheduling]
        var limitations: Set<RunningEvidenceLimitation> = [.legacyAggregate]
        if session.discipline == .strength {
            rules.insert(.strengthSupport)
        } else {
            rules.formUnion([.displayRounding, .paceCalibration])
            if session.runType == .long || session.runType == .progression { rules.insert(.longRunDose) }
            if session.isHardRun { rules.formUnion([.qualityDose, .intensityDistribution]) }
            if session.runType == .race { rules.insert(.raceTerminal) }
        }
        if session.intervals != nil { limitations.insert(.unstructuredLegacyInterval) }
        if request.legacyBridge?.inputs.runningExperience == .new {
            rules.insert(.returnProgression)
            limitations.insert(.noProgressionGate)
        }
        return SessionIntent(
            id: "legacy:\(request.id.uuidString.lowercased()):w\(week.index):d\(session.dayOffset):o\(occurrence)",
            version: 1,
            weekIndex: week.index,
            dayOffset: session.dayOffset,
            discipline: session.discipline,
            legacyRunType: session.runType,
            stimulus: stimulus,
            sessionClass: sessionClass,
            progressionLevel: week.index,
            hardClass: session.isHardLowerLift ? .hardLowerBodyStrength : session.isHardRun ? .hardRun : .none,
            targetHierarchy: hierarchy,
            workDose: RunningWorkDose(
                distanceM: session.targetDistanceM,
                durationS: session.targetDurationS,
                paceSPerKm: session.targetPaceSPerKm,
                intervalPrescription: session.intervals,
                strengthTargets: session.strengthTargets.map(RunningStrengthTarget.init)
            ),
            recoveryDose: nil,
            successRange: nil,
            expectedRecoveryCost: session.isHardRun || session.isHardLowerLift ? .high
                : sessionClass == .long ? .moderate : .low,
            validSubstitutionIDs: [],
            minimumEvidenceToProgress: RunningProgressionEvidenceRequirement(
                minimumCompletedExposures: 0,
                minimumConfidence: .unknown
            ),
            purpose: purpose(session),
            ruleIDs: rules.sorted { $0.rawValue < $1.rawValue },
            limitations: limitations
        )
    }

    static func completedCarryoverIDs(from existing: ExistingRunningPlanSnapshot?,
                                      startDate: Date,
                                      calendar: Calendar) -> [UUID] {
        guard let existing,
              let weekStart = calendar.dateInterval(of: .weekOfYear, for: startDate)?.start else {
            return []
        }
        let raceFloor = calendar.date(byAdding: .weekOfYear, value: -8, to: startDate) ?? weekStart
        return existing.sessions.filter {
            $0.status == .completed && $0.date <= startDate
                && ($0.date >= weekStart || ($0.runType == .race && $0.date >= raceFloor))
        }.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }.map(\.id)
    }

    private static func stimulus(_ session: GeneratedSession) -> RunningStimulus {
        if session.discipline == .strength { return .strengthSupport }
        guard session.discipline == .running else { return .aerobicEndurance }
        switch session.runType {
        case .easy, .freeRun, nil: return .aerobicEndurance
        case .long: return .longEndurance
        case .recovery: return .recovery
        case .tempo: return .threshold
        case .intervals:
            let text = session.intervals?.lowercased() ?? ""
            if text.contains("threshold") { return .threshold }
            if text.contains("race pace") { return .raceSpecific }
            return .vo2
        case .race: return .competition
        case .fartlek, .strides: return .speedNeuromuscular
        case .hills: return .hillStrength
        case .progression: return .progression
        }
    }

    private static func sessionClass(_ session: GeneratedSession) -> RunningIntentSessionClass {
        if session.discipline == .strength { return .strength }
        if session.discipline != .running { return .crossTraining }
        if session.runType == .race { return .race }
        if session.runType == .long || session.runType == .progression { return .long }
        if session.isHardRun { return .quality }
        return .easy
    }

    private static func targetHierarchy(_ session: GeneratedSession) -> RunningTargetHierarchy {
        if session.discipline == .strength {
            return RunningTargetHierarchy(primary: .strengthPrescription)
        }
        if session.intervals != nil {
            return RunningTargetHierarchy(primary: .intervalStructure, fallbacks: [.effort])
        }
        if session.targetDistanceM != nil {
            var fallbacks: [RunningTargetKind] = []
            if session.targetDurationS != nil { fallbacks.append(.duration) }
            if session.targetPaceSPerKm != nil { fallbacks.append(.pace) }
            fallbacks.append(.effort)
            return RunningTargetHierarchy(primary: .distance, fallbacks: fallbacks)
        }
        if session.targetDurationS != nil {
            return RunningTargetHierarchy(primary: .duration, fallbacks: [.effort])
        }
        return RunningTargetHierarchy(primary: .completion, fallbacks: [.effort])
    }

    private static func purpose(_ session: GeneratedSession) -> String {
        if session.discipline == .strength { return "Support running with a recovery-spaced strength dose." }
        return switch session.runType {
        case .long: "Extend aerobic endurance without turning the session into a race."
        case .progression: "Practice finishing with controlled pace after accumulated easy running."
        case .tempo: "Accumulate controlled threshold-oriented work."
        case .intervals: "Accumulate a bounded faster-running dose with recovery between efforts."
        case .fartlek: "Introduce flexible faster running inside an otherwise controlled session."
        case .hills: "Build running-specific force on an appropriate incline."
        case .strides: "Practice short relaxed speed with low total dose."
        case .recovery: "Maintain gentle movement while protecting recovery."
        case .race: "Execute the named primary event."
        case .easy, .freeRun, nil: "Build repeatable aerobic volume at an easy effort."
        }
    }

    private static func limitations(for exception: LegacyPlanException) -> Set<RunningEvidenceLimitation> {
        switch exception.code {
        case .startReturnContinuityGateUnavailable: [.noProgressionGate]
        case .intervalPrescriptionIsUnstructured: [.unstructuredLegacyInterval]
        default: [.legacyAggregate]
        }
    }

    private static func exact(_ value: Double) -> RunningValueRange {
        RunningValueRange(lower: value, upper: value)
    }

    private static func sameNumber(_ lhs: Double?,
                                   _ rhs: Double?,
                                   tolerance: Double = 0.01) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (left?, right?):
            left.isFinite && right.isFinite && abs(left - right) <= tolerance
        case (.some, nil), (nil, .some):
            false
        }
    }

    private static func legacyRunDays(_ inputs: PlanInputs) -> Int {
        let days = max(1, min(7, inputs.daysPerWeek))
        guard inputs.disciplines.contains(.strength) else { return days }
        return PlanEngine.hybridSplit(
            days: days,
            priority: inputs.hybridPriority,
            goal: inputs.goal,
            raceDistanceM: inputs.raceDate != nil ? inputs.raceDistanceM : nil
        ).runDays
    }

    private static func unique(_ conflicts: [RunningPlanningConflict]) -> [RunningPlanningConflict] {
        var seen = Set<String>()
        return conflicts.filter { seen.insert("\($0.code.rawValue)|\($0.field)").inserted }
    }

    private func traceID(_ request: PlanningRequest, status: RunningDecisionStatus) -> String {
        "legacy:\(request.id.uuidString.lowercased()):\(status.rawValue)"
    }
}
