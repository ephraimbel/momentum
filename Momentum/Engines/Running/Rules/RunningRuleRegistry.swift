import Foundation

enum RunningRuleID: String, Codable, CaseIterable, Hashable, Sendable {
    case healthBoundary = "RUN-HEALTH-BOUNDARY-001"
    case loadContext = "RUN-LOAD-CONTEXT-001"
    case loadGovernor = "RUN-LOAD-GOVERNOR-001"
    case loadAdaptation = "RUN-LOAD-ADAPT-001"
    case intensityDistribution = "RUN-TID-001"
    case recoverySignals = "RUN-RECOVERY-001"
    case injuryHistory = "RUN-INJURY-001"
    case feasibility = "RUN-FEASIBILITY-001"
    case fueling = "RUN-FUEL-001"
    case strengthSupport = "RUN-STRENGTH-001"
    case paceCalibration = "RUN-PACE-CALIBRATION-001"
    case racePrediction = "RUN-RACE-PREDICTION-001"
    case weeklyVolumeProgression = "RUN-VOLUME-PROGRESSION-001"
    case peakVolume = "RUN-PEAK-VOLUME-001"
    case longRunDose = "RUN-LONG-DOSE-001"
    case qualityDose = "RUN-QUALITY-DOSE-001"
    case deloadCadence = "RUN-DELOAD-001"
    case taperShape = "RUN-TAPER-001"
    case returnProgression = "RUN-RETURN-001"
    case hardDaySpacing = "RUN-SPACING-001"
    case calendarScheduling = "RUN-SCHEDULE-001"
    case displayRounding = "RUN-ROUNDING-001"
    case environmentAdjustment = "RUN-ENVIRONMENT-001"
    case raceTerminal = "RUN-RACE-TERMINAL-001"
    case selfCoachedBoundary = "RUN-SELF-COACHED-001"
}

enum RunningRuleSourceType: String, Codable, CaseIterable, Sendable {
    case publishedEvidence
    case expertConsensus
    case productDoctrine
    case operationalConstraint
    case provisionalHeuristic
}

enum RunningRuleConfidence: String, Codable, CaseIterable, Sendable {
    case unknown
    case low
    case moderate
    case high
    case operational
}

enum RunningRuleApprovalState: String, Codable, CaseIterable, Sendable {
    case lockedProduct
    case engineeringVerified
    case expertReviewRequired
    case pilotRequired
    case deprecated

    var requiresApprovalDate: Bool {
        self == .lockedProduct || self == .engineeringVerified || self == .deprecated
    }
}

enum RunningRuleOwnerRole: String, Codable, CaseIterable, Hashable, Sendable {
    case product
    case runningEngineering
    case sportScience
    case clinical
    case privacy
    case healthKitEngineering
    case sportsDietitian
    case statistics
}

enum RunningRuleUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case categorical
    case dimensionless
    case fraction
    case meters
    case seconds
    case secondsPerKilometer
    case days
    case weeks
    case sessionsPerWeek
    case workouts
    case beatsPerMinute
    case kilograms
}

struct RunningRuleBound: Codable, Equatable, Sendable {
    let name: String
    let unit: RunningRuleUnit
    let lower: Double?
    let upper: Double?

    init(_ name: String,
         unit: RunningRuleUnit,
         lower: Double? = nil,
         upper: Double? = nil) {
        self.name = name
        self.unit = unit
        self.lower = lower
        self.upper = upper
    }

    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if unit == .categorical { return lower == nil && upper == nil }
        if let lower, !lower.isFinite { return false }
        if let upper, !upper.isFinite { return false }
        if let lower, let upper, lower > upper { return false }
        return lower != nil || upper != nil
    }
}

struct RunningRuleDefinition: Codable, Equatable, Sendable {
    let id: RunningRuleID
    let version: Int
    let policies: Set<RunningPolicyID>
    let codeSymbol: String
    let purpose: String
    let supportedPopulation: String
    let inputUnits: Set<RunningRuleUnit>
    let outputUnits: Set<RunningRuleUnit>
    let bounds: [RunningRuleBound]
    let fallback: String
    let sourceType: RunningRuleSourceType
    let sourceReference: String
    let populationLimitations: String
    let confidence: RunningRuleConfidence
    let approvalState: RunningRuleApprovalState
    let approvalDate: Date?
    let ownerRoles: Set<RunningRuleOwnerRole>
    let governanceReviewedAt: Date?
    let nextReviewAt: Date?
    let fixtureNames: [String]
    let copyDependencies: [String]
    let deprecated: Bool
}

enum RunningRuleRegistryValidationCode: String, Codable, CaseIterable, Sendable {
    case duplicateRuleID
    case missingRequiredRule
    case invalidVersion
    case missingPolicy
    case missingCodeSymbol
    case missingPurpose
    case missingPopulation
    case missingUnits
    case invalidBound
    case missingFallback
    case missingSource
    case missingOwner
    case missingGovernanceReview
    case missingNextReview
    case invalidReviewOrder
    case staleReview
    case missingApprovalDate
    case missingFixture
    case inconsistentDeprecation
}

struct RunningRuleRegistryValidationIssue: Codable, Equatable, Sendable {
    let code: RunningRuleRegistryValidationCode
    let ruleID: RunningRuleID?
    let detail: String
}

/// Compiled source of truth. Remote configuration may select this complete ruleset, but it cannot
/// replace or tune any rule value.
struct RunningRuleRegistry: Sendable {
    let rulesetID: String
    let definitions: [RunningRuleDefinition]
    private let byID: [RunningRuleID: RunningRuleDefinition]

    init(rulesetID: String, definitions: [RunningRuleDefinition]) {
        self.rulesetID = rulesetID
        self.definitions = definitions
        byID = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    subscript(_ id: RunningRuleID) -> RunningRuleDefinition? { byID[id] }

    var validationIssues: [RunningRuleRegistryValidationIssue] {
        validationIssues(asOf: nil)
    }

    /// Build/release qualification supplies an explicit date so an expired governance review fails
    /// closed without making ordinary runtime behavior depend on a user's device clock.
    func validationIssues(asOf qualificationDate: Date?) -> [RunningRuleRegistryValidationIssue] {
        var issues: [RunningRuleRegistryValidationIssue] = []
        let grouped = Dictionary(grouping: definitions, by: \.id)
        for (id, entries) in grouped where entries.count > 1 {
            issues.append(.init(code: .duplicateRuleID, ruleID: id,
                                detail: "Rule ID appears \(entries.count) times."))
        }
        for id in RunningRuleID.allCases where byID[id] == nil {
            issues.append(.init(code: .missingRequiredRule, ruleID: id,
                                detail: "Required compiled rule is absent."))
        }
        for rule in definitions {
            func require(_ condition: Bool,
                         _ code: RunningRuleRegistryValidationCode,
                         _ detail: String) {
                if !condition { issues.append(.init(code: code, ruleID: rule.id, detail: detail)) }
            }
            require(rule.version > 0, .invalidVersion, "Version must be positive.")
            require(!rule.policies.isEmpty, .missingPolicy, "At least one owning policy is required.")
            require(!rule.codeSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    .missingCodeSymbol, "Code symbol is required.")
            require(!rule.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    .missingPurpose, "Purpose is required.")
            require(!rule.supportedPopulation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    .missingPopulation, "Supported population is required.")
            require(!rule.inputUnits.isEmpty && !rule.outputUnits.isEmpty,
                    .missingUnits, "Input and output units are required.")
            require(rule.bounds.allSatisfy(\.isValid), .invalidBound, "Bounds or units are invalid.")
            require(!rule.fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    .missingFallback, "Fallback is required.")
            require(!rule.sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    .missingSource, "Source reference is required.")
            require(!rule.ownerRoles.isEmpty, .missingOwner, "At least one accountable role is required.")
            require(rule.governanceReviewedAt != nil, .missingGovernanceReview,
                    "Governance review date is required.")
            require(rule.nextReviewAt != nil, .missingNextReview, "Next review date is required.")
            if let reviewed = rule.governanceReviewedAt, let next = rule.nextReviewAt {
                require(next > reviewed, .invalidReviewOrder, "Next review must follow governance review.")
                if let qualificationDate {
                    require(next > qualificationDate, .staleReview,
                            "Rule review is expired for this qualification date.")
                }
            }
            if rule.approvalState.requiresApprovalDate {
                require(rule.approvalDate != nil, .missingApprovalDate,
                        "Locked/verified/deprecated entries require an approval date.")
            }
            require(!rule.fixtureNames.isEmpty, .missingFixture, "At least one executable fixture is required.")
            require(rule.deprecated == (rule.approvalState == .deprecated),
                    .inconsistentDeprecation, "Deprecation flag and approval state disagree.")
        }
        return issues.sorted {
            let l = $0.ruleID?.rawValue ?? ""
            let r = $1.ruleID?.rawValue ?? ""
            return l == r ? $0.code.rawValue < $1.code.rawValue : l < r
        }
    }

    var isComplete: Bool { validationIssues.isEmpty }
}

extension RunningRuleRegistry {
    static let legacyRoadV1: RunningRuleRegistry = {
        let reviewed = registryDate(year: 2026, month: 9, day: 1)
        let nextReview = registryDate(year: 2027, month: 3, day: 1)
        let allRoad: Set<RunningPolicyID> = [
            .legacyRoadV1, .startReturnRoadV1, .road5K10KV1, .roadHalfMarathonV1, .roadMarathonV1,
        ]

        func rule(_ id: RunningRuleID,
                  symbol: String,
                  purpose: String,
                  input: Set<RunningRuleUnit>,
                  output: Set<RunningRuleUnit>,
                  bounds: [RunningRuleBound] = [],
                  fallback: String,
                  source: RunningRuleSourceType,
                  reference: String,
                  confidence: RunningRuleConfidence = .operational,
                  approval: RunningRuleApprovalState = .expertReviewRequired,
                  owners: Set<RunningRuleOwnerRole> = [.runningEngineering, .sportScience],
                  fixtures: [String]) -> RunningRuleDefinition {
            RunningRuleDefinition(
                id: id,
                version: 1,
                policies: allRoad,
                codeSymbol: symbol,
                purpose: purpose,
                supportedPopulation: "Release-1 adult road runners, beginner through competitive, 5K through marathon where applicable.",
                inputUnits: input,
                outputUnits: output,
                bounds: bounds,
                fallback: fallback,
                sourceType: source,
                sourceReference: reference,
                populationLimitations: "Not qualified for youth, pregnancy/postpartum, para/adaptive needs, active clinical return, trail/ultra, or middle-distance specialization.",
                confidence: confidence,
                approvalState: approval,
                approvalDate: approval.requiresApprovalDate ? reviewed : nil,
                ownerRoles: owners,
                governanceReviewedAt: reviewed,
                nextReviewAt: nextReview,
                fixtureNames: fixtures,
                copyDependencies: ["Plan creation, adjustment, reveal, explanation, and paywall goal promise where applicable."],
                deprecated: approval == .deprecated
            )
        }

        let entries: [RunningRuleDefinition] = [
            rule(.healthBoundary, symbol: "HealthService / HealthSignalConnection",
                 purpose: "Keep Health recovery signals forward-only and prevent workout import.",
                 input: [.categorical], output: [.workouts],
                 bounds: [.init("imported workout rows", unit: .workouts, lower: 0, upper: 0)],
                 fallback: "Plan from Momentum workouts and explicit athlete input without blocking.",
                 source: .productDoctrine, reference: "docs/RUNNING-EVIDENCE-REGISTRY.md#run-health-boundary-001-v1",
                 approval: .lockedProduct, owners: [.product, .privacy, .healthKitEngineering],
                 fixtures: ["HealthSignalConnectionTests"]),
            rule(.loadContext, symbol: "TrainingLoadContext",
                 purpose: "Describe recent seven-day exposure against the recent weekly norm without claiming injury risk.",
                 input: [.dimensionless], output: [.dimensionless],
                 bounds: [.init("descriptive ratio", unit: .dimensionless, lower: 0)],
                 fallback: "Show raw weekly training and explicit uncertainty.",
                 source: .publishedEvidence, reference: "docs/RUNNING-EVIDENCE-REGISTRY.md#run-load-context-001-v1",
                 confidence: .low, fixtures: ["TrainingLoadContextTests"]),
            rule(.loadGovernor, symbol: "ACWRGovernor.maxRatio / PlanEngine",
                 purpose: "Reduction-only guard against abrupt planned-volume jumps.",
                 input: [.meters, .dimensionless], output: [.fraction],
                 bounds: [.init("recent-to-usual cap", unit: .dimensionless, lower: 1.3, upper: 1.3),
                          .init("dose scale", unit: .fraction, lower: 0, upper: 1)],
                 fallback: "Leave a valid lower-dose week; never add work.",
                 source: .operationalConstraint, reference: "docs/RUNNING-EVIDENCE-REGISTRY.md#run-load-governor-001-v1",
                 fixtures: ["ACWRGovernorTests", "RunningPlannerAdversarialTests"]),
            rule(.loadAdaptation, symbol: "PlanCoaching.autoAdapt / RecoveryAdaptation.tripwire",
                 purpose: "Require response evidence before structural easing and athlete consent before increases.",
                 input: [.dimensionless, .categorical], output: [.fraction, .days],
                 bounds: [.init("structural change interval", unit: .days, lower: 7),
                          .init("automatic dose scale", unit: .fraction, lower: 0, upper: 1)],
                 fallback: "Leave the live plan unchanged and explain the context.",
                 source: .operationalConstraint, reference: "docs/RUNNING-EVIDENCE-REGISTRY.md#run-load-adapt-001-v1",
                 fixtures: ["PlanCoachingTests", "RecoveryAdaptationTests"]),
            rule(.intensityDistribution, symbol: "IntensityMix / PlanEngine.qualityWorkout",
                 purpose: "Keep most endurance work easy while selecting event- and phase-appropriate quality.",
                 input: [.sessionsPerWeek, .categorical], output: [.fraction, .categorical],
                 bounds: [.init("distribution family", unit: .categorical)],
                 fallback: "Use fewer quality exposures and effort-first easy running.",
                 source: .publishedEvidence, reference: "docs/RUNNING-EVIDENCE-REGISTRY.md#run-tid-001-v1",
                 confidence: .moderate, fixtures: ["IntensityMixTests", "RunningPlannerGoldenTests"]),
            rule(.recoverySignals, symbol: "RecoveryAdaptation",
                 purpose: "Require converging recovery signals for easing and never use positive signals to add work.",
                 input: [.categorical, .beatsPerMinute, .seconds], output: [.fraction],
                 bounds: [.init("minimum warning signals", unit: .dimensionless, lower: 2, upper: 2),
                          .init("automatic dose scale", unit: .fraction, lower: 0, upper: 1)],
                 fallback: "Follow effort-first guidance and ask how the athlete feels.",
                 source: .provisionalHeuristic, reference: "docs/RUNNING-EVIDENCE-REGISTRY.md#run-recovery-001-v1",
                 confidence: .low, fixtures: ["RecoveryAdaptationTests", "RecoveryModelTests"]),
            rule(.injuryHistory, symbol: "PlanEngine.impactSensitiveAreas / InjuryResponse",
                 purpose: "Use prior history conservatively and active symptoms only to reduce, substitute, hold, or escalate.",
                 input: [.categorical], output: [.fraction, .categorical],
                 bounds: [.init("dose scale", unit: .fraction, lower: 0, upper: 1)],
                 fallback: "Stop generated progression and route concerning cases to qualified care.",
                 source: .expertConsensus, reference: "docs/RUNNING-EVIDENCE-REGISTRY.md#run-injury-001-v1",
                 confidence: .low, owners: [.clinical, .sportScience, .runningEngineering],
                 fixtures: ["InjuryResponseTests", "RunningPlannerValidatorTests"]),
            rule(.feasibility, symbol: "PlanFeasibility.assess",
                 purpose: "Judge requested outcome, runway, current evidence, and availability before generation.",
                 input: [.meters, .seconds, .weeks, .sessionsPerWeek], output: [.categorical, .weeks, .seconds],
                 bounds: [.init("generated horizon", unit: .weeks, lower: 1, upper: 52)],
                 fallback: "Return an honest conflict or conservative legacy verdict without changing the named goal.",
                 source: .provisionalHeuristic, reference: "docs/RUNNING-EVIDENCE-REGISTRY.md#run-feasibility-001-v1",
                 confidence: .low, owners: [.product, .sportScience, .statistics, .runningEngineering],
                 fixtures: ["PlanFeasibilityTests", "LegacyRoadPolicyAdapterTests"]),
            rule(.fueling, symbol: "FuelingGuide / FuelReadiness",
                 purpose: "Use fueling floors tied to training, never dieting ceilings or treatment claims.",
                 input: [.seconds, .categorical], output: [.categorical],
                 bounds: [.init("fueling policy", unit: .categorical)],
                 fallback: "Use familiar food, practice in training, and qualified individualized guidance.",
                 source: .publishedEvidence, reference: "docs/RUNNING-EVIDENCE-REGISTRY.md#run-fuel-001-v1",
                 confidence: .moderate, owners: [.sportsDietitian, .product, .sportScience],
                 fixtures: ["FuelingGuideTests", "FuelReadinessTests"]),
            rule(.strengthSupport, symbol: "PlanEngine.strengthSessions / HybridSequencing",
                 purpose: "Keep strength progressive, recovery-spaced, and subordinate to the running outcome.",
                 input: [.sessionsPerWeek, .categorical], output: [.sessionsPerWeek, .categorical],
                 bounds: [.init("strength sessions", unit: .sessionsPerWeek, lower: 0, upper: 7)],
                 fallback: "Use minimal runner-strength support or omit it when the week cannot recover from it.",
                 source: .publishedEvidence, reference: "docs/RUNNING-EVIDENCE-REGISTRY.md#run-strength-001-v1",
                 confidence: .moderate, fixtures: ["PlanEngineTests", "HybridSequencingTests"]),
            rule(.paceCalibration, symbol: "PlanEngine.riegelP5k / levelP5k",
                 purpose: "Select the best available pace seed without treating missing evidence as measured fitness.",
                 input: [.meters, .seconds, .categorical], output: [.secondsPerKilometer],
                 bounds: [.init("accepted plan pace", unit: .secondsPerKilometer, lower: 120, upper: 1_200)],
                 fallback: "Use the explicit experience-level legacy default and mark evidence unknown.",
                 source: .provisionalHeuristic, reference: "Momentum/Engines/PlanEngine.swift#riegelP5k",
                 confidence: .low, fixtures: ["PlanEngineTests", "RunningPlannerSemanticTests"]),
            rule(.racePrediction, symbol: "PlanFeasibility.predictedFinishS / DanielsPaces.enduranceCorrected",
                 purpose: "Estimate a finish range from supported performance evidence while naming extrapolation limits.",
                 input: [.meters, .secondsPerKilometer], output: [.seconds],
                 bounds: [.init("release-one distance", unit: .meters, lower: 5_000, upper: 42_195)],
                 fallback: "Return unknown when comparable performance evidence is absent.",
                 source: .provisionalHeuristic, reference: "Momentum/Engines/PlanFeasibility.swift#predictedFinishS",
                 confidence: .low, owners: [.statistics, .sportScience, .runningEngineering],
                 fixtures: ["PlanFeasibilityTests"]),
            rule(.weeklyVolumeProgression, symbol: "PlanIntensity.weeklyRamp / PlanEngine.generate",
                 purpose: "Bound week-to-week planned-volume progression before reduction-only guards.",
                 input: [.meters, .categorical], output: [.dimensionless],
                 bounds: [.init("runway-fitted ramp", unit: .dimensionless, lower: 1, upper: 1.15)],
                 fallback: "Hold or reduce volume; never exceed the compiled ceiling.",
                 source: .provisionalHeuristic, reference: "Momentum/Engines/PlanFeasibility.swift#PlanIntensity.weeklyRamp",
                 fixtures: ["PlanEngineInvariantTests", "RunningPlannerAdversarialTests"]),
            rule(.peakVolume, symbol: "PlanFeasibility.peakWeeklyVolumeM / PlanEngine.multCeiling",
                 purpose: "Set a bounded weekly-volume destination from event, experience, current load, and athlete cap.",
                 input: [.meters, .seconds, .categorical], output: [.meters, .dimensionless],
                 bounds: [.init("legacy peak multiplier", unit: .dimensionless, lower: 1, upper: 3.5)],
                 fallback: "Use a bounded open-block ceiling and honor the athlete's lower cap.",
                 source: .provisionalHeuristic, reference: "Momentum/Engines/PlanFeasibility.swift#peakWeeklyVolumeM",
                 fixtures: ["PlanFeasibilityTests", "RunningPlannerGoldenTests"]),
            rule(.longRunDose, symbol: "PlanEngine.longRunPeak / longRunWave",
                 purpose: "Bound long-run exposure by event distance, weekly dose, experience context, and phase.",
                 input: [.meters, .categorical], output: [.meters, .fraction],
                 bounds: [.init("road long-run ceiling", unit: .meters, lower: 0, upper: 35_000),
                          .init("low-frequency long share", unit: .fraction, lower: 0, upper: 0.55)],
                 fallback: "Use the lower event/week-derived dose and keep it easy.",
                 source: .provisionalHeuristic, reference: "Momentum/Engines/PlanEngine.swift#longRunPeak",
                 fixtures: ["PlanProfessionalAuditTests", "RunningPlannerValidatorTests"]),
            rule(.qualityDose, symbol: "PlanEngine.qualityWorkout / secondQualityWorkout",
                 purpose: "Bound quality frequency and work dose by phase, volume, experience, and response modifiers.",
                 input: [.meters, .sessionsPerWeek, .categorical], output: [.sessionsPerWeek, .meters, .seconds],
                 bounds: [.init("quality sessions", unit: .sessionsPerWeek, lower: 0, upper: 2)],
                 fallback: "Use one smaller effort-first quality exposure or an easy run.",
                 source: .provisionalHeuristic, reference: "Momentum/Engines/PlanEngine.swift#qualityWorkout",
                 fixtures: ["PlanProfessionalAuditTests", "RunningPlannerGoldenTests"]),
            rule(.deloadCadence, symbol: "PlanEngine.generate isDeload",
                 purpose: "Insert absorption weeks and ensure final reduced dose is below the prior loading week.",
                 input: [.weeks, .categorical], output: [.fraction, .weeks],
                 bounds: [.init("loading weeks before deload", unit: .weeks, lower: 2, upper: 4),
                          .init("legacy deload multiplier", unit: .fraction, lower: 0.7, upper: 0.7)],
                 fallback: "Reduce only; a failed final invariant rejects the candidate.",
                 source: .provisionalHeuristic, reference: "Momentum/Engines/PlanEngine.swift#isDeload",
                 fixtures: ["RunningPlannerValidatorTests", "RunningPlannerAdversarialTests"]),
            rule(.taperShape, symbol: "PlanEngine.taperMultipliers / mesocycle",
                 purpose: "Reduce volume while retaining bounded race-specific intensity before the primary road race.",
                 input: [.meters, .weeks, .categorical], output: [.fraction, .weeks],
                 bounds: [.init("release-one taper weeks", unit: .weeks, lower: 1, upper: 3),
                          .init("legacy taper fraction", unit: .fraction, lower: 0.45, upper: 0.70)],
                 fallback: "Use the shorter compiled taper that fits the runway; never add post-race training.",
                 source: .publishedEvidence, reference: "Momentum/Engines/PlanEngine.swift#taperMultipliers",
                 confidence: .moderate, fixtures: ["PlanEngineTests", "RunningPlannerGoldenTests"]),
            rule(.returnProgression, symbol: "LegacyRoadPolicyAdapter / future StartReturnRoadPolicy",
                 purpose: "Require continuity and response gates before progressing a start/return runner.",
                 input: [.weeks, .sessionsPerWeek, .categorical], output: [.categorical, .fraction],
                 bounds: [.init("progression gate", unit: .categorical)],
                 fallback: "Legacy adapter reports no progression gate and does not claim qualified return coaching.",
                 source: .expertConsensus, reference: "docs/RUNNING-LEGACY-EXCEPTIONS.md#startreturncontinuitygateunavailable",
                 confidence: .unknown, owners: [.clinical, .sportScience, .runningEngineering],
                 fixtures: ["LegacyRoadPolicyAdapterTests", "RunningPlannerValidatorTests"]),
            rule(.hardDaySpacing, symbol: "PlanEngine.schedule / scheduleSatisfiesRecovery",
                 purpose: "Keep hard running off the day immediately after hard lower-body strength and prefer separated hard runs.",
                 input: [.days, .categorical], output: [.days, .categorical],
                 bounds: [.init("protected lower-strength interval", unit: .days, lower: 1, upper: 1)],
                 fallback: "Downgrade the run to easy when the requested week cannot satisfy the hard constraint.",
                 source: .operationalConstraint, reference: "Momentum/Engines/PlanEngine.swift#schedule",
                 approval: .engineeringVerified, fixtures: ["HybridSequencingTests", "RunningPlannerValidatorTests"]),
            rule(.calendarScheduling, symbol: "PlanEngine.schedule / weeksToRace",
                 purpose: "Place sessions deterministically inside the injected calendar and availability budget.",
                 input: [.days, .sessionsPerWeek, .categorical], output: [.days],
                 bounds: [.init("week day offset", unit: .days, lower: 0, upper: 6)],
                 fallback: "Use stable even spacing after hard constraints; never randomize.",
                 source: .operationalConstraint, reference: "Momentum/Engines/PlanEngine.swift#schedule",
                 approval: .engineeringVerified, fixtures: ["PlanEngineTests", "RunningPlannerSemanticTests"]),
            rule(.displayRounding, symbol: "RunRounding.snap / snapPace",
                 purpose: "Round only after dose calculation in the athlete's display unit while storing SI.",
                 input: [.meters, .secondsPerKilometer, .categorical], output: [.meters, .secondsPerKilometer],
                 bounds: [.init("distance increment in display units", unit: .dimensionless, lower: 0.5, upper: 1),
                          .init("pace increment", unit: .seconds, lower: 5, upper: 15)],
                 fallback: "Preserve the lower guarded dose even when a later reduction leaves it off-grid.",
                 source: .operationalConstraint, reference: "Momentum/Engines/RunRounding.swift",
                 approval: .engineeringVerified, fixtures: ["RunRoundingTests", "LegacyRoadPolicyAdapterTests"]),
            rule(.environmentAdjustment, symbol: "future TargetCalibrationPass",
                 purpose: "Adjust targets only from known comparable environment evidence.",
                 input: [.categorical], output: [.categorical, .secondsPerKilometer],
                 bounds: [.init("environment support", unit: .categorical)],
                 fallback: "Do not adjust; attach missing-environment or non-comparable limitation.",
                 source: .provisionalHeuristic, reference: "docs/ELITE-RUNNING-SYSTEM.md#182-planning-request-and-athlete-state",
                 confidence: .unknown, fixtures: ["RunningDomainContractTests"]),
            rule(.raceTerminal, symbol: "PlanEngine.generate race insertion / LegacyPlanInvariantValidator",
                 purpose: "Make the primary A race terminal unless an explicit recovery/next block exists.",
                 input: [.days, .categorical], output: [.workouts],
                 bounds: [.init("training sessions after terminal race", unit: .workouts, lower: 0, upper: 0)],
                 fallback: "Reject the candidate and keep the current plan.",
                 source: .operationalConstraint, reference: "docs/ELITE-RUNNING-SYSTEM.md#193-hard-constraints",
                 approval: .engineeringVerified, fixtures: ["RunningPlannerValidatorTests"]),
            rule(.selfCoachedBoundary, symbol: "LegacyRoadPolicyAdapter / PlanCoaching self-coached guards",
                 purpose: "Observe a self-coached plan without generated recalibration or structural edits.",
                 input: [.categorical], output: [.workouts],
                 bounds: [.init("automatic generated changes", unit: .workouts, lower: 0, upper: 0)],
                 fallback: "Return a protected result; only an explicit athlete request may create a coached replacement.",
                 source: .productDoctrine, reference: "docs/ELITE-RUNNING-SYSTEM.md#193-hard-constraints",
                 approval: .lockedProduct, owners: [.product, .runningEngineering],
                 fixtures: ["SelfCoachedPlanTests", "LegacyRoadPolicyAdapterTests"]),
        ]
        return RunningRuleRegistry(rulesetID: PlanningRequest.legacyRulesetID, definitions: entries)
    }()

    private static func registryDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
