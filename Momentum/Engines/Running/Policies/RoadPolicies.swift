import Foundation

enum RoadPolicySelectionResult: Equatable, Sendable {
    case selected(RunningPolicyID)
    case conflict(RunningPlanningConflict)
}

/// Explicit policy routing. Unsupported requests stop here; a trail, ultra, or malformed goal is
/// never handed to the nearest road template.
enum RoadPolicyRouter {
    static func select(for request: PlanningRequest) -> RoadPolicySelectionResult {
        if let event = request.season.primaryEvent, event.surface != .road {
            return .conflict(RunningPlanningConflict(
                .unsupportedSurface,
                field: "season.primaryEvent.surface",
                detail: "Release-1 road policies require an explicitly road primary event."
            ))
        }
        let isStartReturn = request.goal.outcome == .returnToRunning
            || request.legacyBridge?.inputs.runningExperience == .new
        if isStartReturn { return .selected(.startReturnRoadV1) }

        let distance = request.goal.targetDistanceM ?? request.season.primaryEvent?.distanceM
        guard let distance else {
            if request.goal.outcome == .buildBase { return .selected(.startReturnRoadV1) }
            return .conflict(RunningPlanningConflict(
                .missingRaceDistance,
                field: "goal.targetDistanceM",
                detail: "Choose a positive road distance before selecting an event policy."
            ))
        }
        guard distance.isFinite, distance > 0, distance <= RaceDistance.marathon.meters + 1 else {
            return .conflict(RunningPlanningConflict(
                .unsupportedDistance,
                field: "goal.targetDistanceM",
                detail: "Release-1 road policies support positive distances through the marathon."
            ))
        }
        if distance <= 10_000 + 1 { return .selected(.road5K10KV1) }
        if distance <= RaceDistance.half.meters + 1 { return .selected(.roadHalfMarathonV1) }
        return .selected(.roadMarathonV1)
    }

    static func policy(_ id: RunningPolicyID,
                       catalog: [ExerciseCatalogItem],
                       registry: RunningRuleRegistry = .legacyRoadV1) -> any RunningPolicy {
        switch id {
        case .startReturnRoadV1:
            StartReturnRoadPolicy(catalog: catalog, registry: registry)
        case .road5K10KV1:
            Road5K10KPolicy(catalog: catalog, registry: registry)
        case .roadHalfMarathonV1:
            HalfMarathonRoadPolicy(catalog: catalog, registry: registry)
        case .roadMarathonV1:
            MarathonRoadPolicy(catalog: catalog, registry: registry)
        case .legacyRoadV1:
            LegacyRoadPolicyAdapter(catalog: catalog, registry: registry)
        }
    }
}

struct StartReturnRoadPolicy: RunningPolicy {
    let id: RunningPolicyID = .startReturnRoadV1
    let version = 1
    private let legacy: LegacyRoadPolicyAdapter

    init(catalog: [ExerciseCatalogItem], registry: RunningRuleRegistry = .legacyRoadV1) {
        legacy = LegacyRoadPolicyAdapter(catalog: catalog, registry: registry)
    }

    func feasibility(for request: PlanningRequest) -> FeasibilityResult {
        RoadPolicySemantics.feasibility(expected: id, request: request, legacy: legacy)
    }

    func blockMap(for request: PlanningRequest) -> [BlockIntent] {
        RoadPolicySemantics.project(legacy.blockMap(for: request), for: id)
    }

    func weeklyDose(for context: PolicyWeekContext) -> WeeklyDoseEnvelope {
        legacy.weeklyDose(for: context)
    }

    func sessionIntents(for context: PolicyWeekContext) -> [SessionIntent] {
        RoadPolicySemantics.projectWeek(legacy.sessionIntents(for: context), for: id, context: context)
    }

    func exitDecision(for context: BlockExitContext) -> BlockExitDecision {
        RoadPolicySemantics.exitDecision(for: id, context: context)
    }
}

struct Road5K10KPolicy: RunningPolicy {
    let id: RunningPolicyID = .road5K10KV1
    let version = 1
    private let legacy: LegacyRoadPolicyAdapter

    init(catalog: [ExerciseCatalogItem], registry: RunningRuleRegistry = .legacyRoadV1) {
        legacy = LegacyRoadPolicyAdapter(catalog: catalog, registry: registry)
    }

    func feasibility(for request: PlanningRequest) -> FeasibilityResult {
        RoadPolicySemantics.feasibility(expected: id, request: request, legacy: legacy)
    }

    func blockMap(for request: PlanningRequest) -> [BlockIntent] {
        RoadPolicySemantics.project(legacy.blockMap(for: request), for: id)
    }

    func weeklyDose(for context: PolicyWeekContext) -> WeeklyDoseEnvelope { legacy.weeklyDose(for: context) }

    func sessionIntents(for context: PolicyWeekContext) -> [SessionIntent] {
        RoadPolicySemantics.projectWeek(legacy.sessionIntents(for: context), for: id, context: context)
    }

    func exitDecision(for context: BlockExitContext) -> BlockExitDecision {
        RoadPolicySemantics.exitDecision(for: id, context: context)
    }
}

struct HalfMarathonRoadPolicy: RunningPolicy {
    let id: RunningPolicyID = .roadHalfMarathonV1
    let version = 1
    private let legacy: LegacyRoadPolicyAdapter

    init(catalog: [ExerciseCatalogItem], registry: RunningRuleRegistry = .legacyRoadV1) {
        legacy = LegacyRoadPolicyAdapter(catalog: catalog, registry: registry)
    }

    func feasibility(for request: PlanningRequest) -> FeasibilityResult {
        RoadPolicySemantics.feasibility(expected: id, request: request, legacy: legacy)
    }

    func blockMap(for request: PlanningRequest) -> [BlockIntent] {
        RoadPolicySemantics.project(legacy.blockMap(for: request), for: id)
    }

    func weeklyDose(for context: PolicyWeekContext) -> WeeklyDoseEnvelope { legacy.weeklyDose(for: context) }

    func sessionIntents(for context: PolicyWeekContext) -> [SessionIntent] {
        RoadPolicySemantics.projectWeek(legacy.sessionIntents(for: context), for: id, context: context)
    }

    func exitDecision(for context: BlockExitContext) -> BlockExitDecision {
        RoadPolicySemantics.exitDecision(for: id, context: context)
    }
}

struct MarathonRoadPolicy: RunningPolicy {
    let id: RunningPolicyID = .roadMarathonV1
    let version = 1
    private let legacy: LegacyRoadPolicyAdapter

    init(catalog: [ExerciseCatalogItem], registry: RunningRuleRegistry = .legacyRoadV1) {
        legacy = LegacyRoadPolicyAdapter(catalog: catalog, registry: registry)
    }

    func feasibility(for request: PlanningRequest) -> FeasibilityResult {
        RoadPolicySemantics.feasibility(expected: id, request: request, legacy: legacy)
    }

    func blockMap(for request: PlanningRequest) -> [BlockIntent] {
        RoadPolicySemantics.project(legacy.blockMap(for: request), for: id)
    }

    func weeklyDose(for context: PolicyWeekContext) -> WeeklyDoseEnvelope { legacy.weeklyDose(for: context) }

    func sessionIntents(for context: PolicyWeekContext) -> [SessionIntent] {
        RoadPolicySemantics.projectWeek(legacy.sessionIntents(for: context), for: id, context: context)
    }

    func exitDecision(for context: BlockExitContext) -> BlockExitDecision {
        RoadPolicySemantics.exitDecision(for: id, context: context)
    }
}

enum RoadPolicySemantics {
    static func projectWeek(_ intents: [SessionIntent],
                            for policy: RunningPolicyID,
                            context: PolicyWeekContext) -> [SessionIntent] {
        var projected = intents.map { project($0, for: policy, context: context) }
        let budget = context.request.availability.trainingDaysPerWeek
        guard projected.count > budget else { return projected }

        // Legacy podium weeks may add an unrequested shakeout above the athlete's day budget. The
        // road policies treat that as optional easy dose and remove the smallest easy sessions
        // first; a key stimulus is never dropped to make a schedule fit.
        let removable = projected.filter {
            $0.sessionClass == .easy && $0.hardClass == .none
        }.sorted {
            // Compare an estimated execution duration, not raw metres against raw seconds.
            // Mixing those SI dimensions could remove a longer run merely because its numeric
            // distance happened to be smaller than another session's duration.
            let left = estimatedWorkDurationS($0) ?? .greatestFiniteMagnitude
            let right = estimatedWorkDurationS($1) ?? .greatestFiniteMagnitude
            return left == right ? $0.id < $1.id : left < right
        }
        let removeCount = projected.count - budget
        guard removable.count >= removeCount else { return projected }
        let removedIDs = Set(removable.prefix(removeCount).map(\.id))
        projected.removeAll { removedIDs.contains($0.id) }
        return projected
    }

    static func feasibility(expected: RunningPolicyID,
                            request: PlanningRequest,
                            legacy: LegacyRoadPolicyAdapter) -> FeasibilityResult {
        switch RoadPolicyRouter.select(for: request) {
        case let .selected(actual) where actual == expected:
            return legacy.feasibility(for: request)
        case let .selected(actual):
            let conflict = RunningPlanningConflict(
                .policyMismatch,
                field: "policyID",
                detail: "Policy \(expected.rawValue) cannot plan a request routed to \(actual.rawValue)."
            )
            return unsupported(conflict)
        case let .conflict(conflict):
            return unsupported(conflict)
        }
    }

    static func project(_ blocks: [BlockIntent], for policy: RunningPolicyID) -> [BlockIntent] {
        blocks.map { block in
            BlockIntent(
                id: block.id.replacingOccurrences(of: "legacy:", with: "\(policy.rawValue):"),
                phase: block.phase,
                firstWeekIndex: block.firstWeekIndex,
                lastWeekIndex: block.lastWeekIndex,
                objective: objective(policy: policy, phase: block.phase),
                ruleIDs: Set(block.ruleIDs).union(policyRules(policy)).sorted { $0.rawValue < $1.rawValue }
            )
        }
    }

    static func project(_ intent: SessionIntent,
                        for policy: RunningPolicyID,
                        context: PolicyWeekContext) -> SessionIntent {
        if policy == .startReturnRoadV1,
           intent.sessionClass != .race,
           intent.hardClass == .hardRun,
           !startReturnQualityGateIsOpen(context.request.athleteState) {
            let easyPace = RunRounding.snapPace(
                sPerKm: PlanEngine.pace(.easy, p5k: context.generatedPlan.p5kSPerKm),
                unit: context.request.displayUnit,
                type: .easy
            )
            let duration = intent.workDose.durationS
                ?? intent.workDose.distanceM.map { $0 / 1_000 * easyPace }
            return SessionIntent(
                id: intent.id,
                version: intent.version,
                weekIndex: intent.weekIndex,
                dayOffset: intent.dayOffset,
                discipline: intent.discipline,
                legacyRunType: .easy,
                stimulus: .aerobicEndurance,
                sessionClass: .easy,
                progressionLevel: intent.progressionLevel,
                hardClass: .none,
                targetHierarchy: RunningTargetHierarchy(primary: .effort, fallbacks: [.duration, .distance]),
                workDose: RunningWorkDose(
                    distanceM: intent.workDose.distanceM,
                    durationS: duration,
                    paceSPerKm: easyPace,
                    intervalPrescription: "Run/walk 1:1",
                    strengthTargets: []
                ),
                recoveryDose: nil,
                successRange: intent.successRange,
                expectedRecoveryCost: .low,
                validSubstitutionIDs: intent.validSubstitutionIDs,
                minimumEvidenceToProgress: .init(minimumCompletedExposures: 2, minimumConfidence: .low),
                purpose: "Build repeatable running tolerance before adding faster work.",
                ruleIDs: Set(intent.ruleIDs).union([.returnProgression, .hardDaySpacing])
                    .sorted { $0.rawValue < $1.rawValue },
                limitations: intent.limitations.subtracting([.noProgressionGate])
            )
        }

        let requirement: RunningProgressionEvidenceRequirement = {
            switch policy {
            case .startReturnRoadV1:
                .init(minimumCompletedExposures: 2, minimumConfidence: .low)
            case .road5K10KV1:
                intent.sessionClass == .quality
                    ? .init(minimumCompletedExposures: 2, minimumConfidence: .moderate)
                    : .init(minimumCompletedExposures: 1, minimumConfidence: .low)
            case .roadHalfMarathonV1, .roadMarathonV1:
                intent.sessionClass == .quality || intent.sessionClass == .long
                    ? .init(minimumCompletedExposures: 2, minimumConfidence: .moderate)
                    : .init(minimumCompletedExposures: 1, minimumConfidence: .low)
            case .legacyRoadV1:
                intent.minimumEvidenceToProgress
            }
        }()
        return intent.replacing(
            targetHierarchy: targetHierarchy(intent, policy: policy),
            minimumEvidenceToProgress: requirement,
            purpose: purpose(intent, policy: policy),
            additionalRuleIDs: policyRules(policy),
            additionalLimitations: policy == .legacyRoadV1 ? [.legacyAggregate] : []
        )
    }

    static func exitDecision(for policy: RunningPolicyID,
                             context: BlockExitContext) -> BlockExitDecision {
        let flags = context.request.athleteState.recentResponseFlags?.value ?? []
        if !context.request.activeRestrictions.isEmpty
            || flags.contains(.activeSymptomsReported)
            || flags.contains(.acuteIllnessConcern) {
            return BlockExitDecision(
                state: .blocked,
                reasons: ["An active restriction or concerning response keeps progression closed."],
                ruleIDs: [.injuryHistory, .returnProgression],
                limitations: []
            )
        }
        if flags.contains(.repeatedIncompleteQuality) || flags.contains(.repeatedIncompleteLongRun) {
            return BlockExitDecision(
                state: .hold,
                reasons: ["Repeated incomplete key sessions hold the current progression level."],
                ruleIDs: [.loadAdaptation],
                limitations: []
            )
        }
        guard context.plannedSessionCount > 0,
              context.completedSessionCount >= context.plannedSessionCount else {
            return BlockExitDecision(
                state: .hold,
                reasons: ["Complete the current block's planned exposures before progressing."],
                ruleIDs: policy == .startReturnRoadV1 ? [.returnProgression] : [.loadAdaptation],
                limitations: []
            )
        }
        if policy == .startReturnRoadV1,
           !startReturnQualityGateIsOpen(context.request.athleteState) {
            return BlockExitDecision(
                state: .hold,
                reasons: ["Two consistent weeks and repeated acceptable easy-run response are still needed."],
                ruleIDs: [.returnProgression],
                limitations: [.smallSample]
            )
        }
        return BlockExitDecision(
            state: context.block.phase == .taper ? .complete : .advance,
            reasons: [context.block.phase == .taper
                ? "The terminal event block is complete."
                : "Completion and response evidence support the next bounded progression."],
            ruleIDs: policy == .startReturnRoadV1 ? [.returnProgression] : [.loadAdaptation],
            limitations: []
        )
    }

    static func startReturnQualityGateIsOpen(_ state: RunningAthleteState) -> Bool {
        let adverse = state.recentResponseFlags?.value ?? []
        guard adverse.isDisjoint(with: [
            .sessionFeltHarderThanPlanned, .repeatedIncompleteQuality,
            .repeatedIncompleteLongRun, .activeSymptomsReported, .acuteIllnessConcern,
        ]) else { return false }
        guard let continuity = state.continuity,
              continuity.source.canRepresentCompletedTrainingExposure,
              continuity.validationIssues.isEmpty,
              continuity.confidence >= .low,
              continuity.value.currentConsecutiveWeeks >= 2,
              let tolerance = state.toleranceBySessionClass[.easy],
              tolerance.source.canRepresentCompletedTrainingExposure,
              tolerance.validationIssues.isEmpty,
              tolerance.confidence >= .low,
              tolerance.value.completedExposureCount >= 2,
              tolerance.value.band == .developing || tolerance.value.band == .established else {
            return false
        }
        return true
    }
}

private extension RoadPolicySemantics {
    static func unsupported(_ conflict: RunningPlanningConflict) -> FeasibilityResult {
        FeasibilityResult(
            verdict: .unsupported,
            weeksAvailable: nil,
            weeksNeeded: nil,
            recommendedIntensity: nil,
            realisticFinishS: nil,
            weeklyCapShortfallM: nil,
            conflicts: [conflict],
            headline: "This goal needs a different policy",
            detail: conflict.detail,
            options: conflict.alternatives
        )
    }

    static func policyRules(_ policy: RunningPolicyID) -> Set<RunningRuleID> {
        switch policy {
        case .startReturnRoadV1: [.returnProgression, .longRunDose]
        case .road5K10KV1: [.intensityDistribution, .qualityDose, .longRunDose]
        case .roadHalfMarathonV1: [.intensityDistribution, .qualityDose, .longRunDose, .fueling]
        case .roadMarathonV1: [.qualityDose, .longRunDose, .fueling, .taperShape]
        case .legacyRoadV1: []
        }
    }

    static func objective(policy: RunningPolicyID, phase: PlanPhase) -> String {
        switch (policy, phase) {
        case (.startReturnRoadV1, .base): "Build repeatable run/walk frequency and impact tolerance"
        case (.startReturnRoadV1, .build), (.startReturnRoadV1, .peak):
            "Progress continuous running only after completion and next-day response gates"
        case (.startReturnRoadV1, .recovery): "Hold or reduce impact while the prior work absorbs"
        case (.startReturnRoadV1, .taper): "Arrive rested for a completion-focused event"
        case (.road5K10KV1, .base): "Establish aerobic consistency before faster running"
        case (.road5K10KV1, .build): "Develop threshold strength and economical speed"
        case (.road5K10KV1, .peak): "Practice bounded event-specific work"
        case (.road5K10KV1, .recovery): "Absorb short-race quality without adding dose"
        case (.road5K10KV1, .taper): "Reduce volume while retaining a short race-specific touch"
        case (.roadHalfMarathonV1, .base): "Build aerobic volume tolerance and long-run durability"
        case (.roadHalfMarathonV1, .build): "Extend threshold duration and controlled event-pace exposure"
        case (.roadHalfMarathonV1, .peak): "Rehearse half-marathon durability and fueling"
        case (.roadHalfMarathonV1, .recovery): "Absorb long and threshold work"
        case (.roadHalfMarathonV1, .taper): "Freshen while retaining half-marathon rhythm"
        case (.roadMarathonV1, .base): "Establish cumulative volume and durable easy running"
        case (.roadMarathonV1, .build): "Grow long-run durability, fueling practice, and marathon-specific work"
        case (.roadMarathonV1, .peak): "Rehearse marathon execution without exceeding proven capacity"
        case (.roadMarathonV1, .recovery): "Absorb cumulative load; never make up missed peak work"
        case (.roadMarathonV1, .taper): "Reduce volume, retain rhythm, and protect race readiness"
        case (.legacyRoadV1, _): "Preserve the legacy block objective"
        }
    }

    static func targetHierarchy(_ intent: SessionIntent,
                                policy: RunningPolicyID) -> RunningTargetHierarchy {
        if intent.discipline == .strength {
            return RunningTargetHierarchy(primary: .strengthPrescription)
        }
        if intent.sessionClass == .race {
            return RunningTargetHierarchy(primary: .completion, fallbacks: [.distance, .effort])
        }
        switch intent.stimulus {
        case .recovery, .aerobicEndurance:
            return RunningTargetHierarchy(primary: .effort, fallbacks: available([.duration, .distance], intent))
        case .longEndurance:
            return RunningTargetHierarchy(primary: .effort, fallbacks: available([.duration, .distance], intent))
        case .threshold:
            return intent.workDose.intervalPrescription == nil
                ? RunningTargetHierarchy(primary: .pace, fallbacks: [.effort])
                : RunningTargetHierarchy(primary: .intervalStructure, fallbacks: [.pace, .effort])
        case .vo2, .speedNeuromuscular:
            return RunningTargetHierarchy(primary: .intervalStructure, fallbacks: [.pace, .effort])
        case .hillStrength:
            return RunningTargetHierarchy(primary: .effort, fallbacks: [.duration])
        case .raceSpecific:
            return intent.workDose.intervalPrescription == nil
                ? RunningTargetHierarchy(primary: .pace, fallbacks: [.effort])
                : RunningTargetHierarchy(primary: .intervalStructure, fallbacks: [.pace, .effort])
        case .progression:
            // A legacy progression is not yet represented by typed segments. A single average
            // pace would overstate precision and can turn a controlled long run into a time trial.
            return RunningTargetHierarchy(
                primary: .effort,
                fallbacks: available([.duration, .distance, .pace], intent)
            )
        case .strengthSupport:
            return RunningTargetHierarchy(primary: .strengthPrescription)
        case .competition:
            return RunningTargetHierarchy(primary: .completion, fallbacks: [.distance, .effort])
        case .unstructured:
            return RunningTargetHierarchy(primary: .effort, fallbacks: available([.duration, .distance], intent))
        }
    }

    static func available(_ targets: [RunningTargetKind], _ intent: SessionIntent) -> [RunningTargetKind] {
        targets.filter {
            switch $0 {
            case .duration:
                intent.workDose.durationS != nil
                    || intent.workDose.paceSPerKm != nil && intent.workDose.distanceM != nil
            case .distance: intent.workDose.distanceM != nil
            case .pace: intent.workDose.paceSPerKm != nil
            case .intervalStructure: intent.workDose.intervalPrescription != nil
            default: true
            }
        }
    }

    static func estimatedWorkDurationS(_ intent: SessionIntent) -> Double? {
        if let duration = intent.workDose.durationS,
           duration.isFinite, duration > 0 {
            return duration
        }
        if let distance = intent.workDose.distanceM,
           let pace = intent.workDose.paceSPerKm,
           distance.isFinite, distance > 0,
           pace.isFinite, pace > 0 {
            return distance / 1_000 * pace
        }
        return nil
    }

    static func purpose(_ intent: SessionIntent, policy: RunningPolicyID) -> String {
        let policyLead: String = switch policy {
        case .startReturnRoadV1: "Build repeatable running tolerance."
        case .road5K10KV1: "Improve road-running economy and speed endurance."
        case .roadHalfMarathonV1: "Build threshold endurance and long-run durability."
        case .roadMarathonV1: "Build marathon durability while protecting recovery."
        case .legacyRoadV1: ""
        }
        return policyLead.isEmpty ? intent.purpose : "\(policyLead) \(intent.purpose)"
    }
}
