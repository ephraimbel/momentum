import Foundation

enum RunningPolicyID: String, Codable, CaseIterable, Hashable, Sendable {
    /// Stage-B umbrella around the shipping generator. It is never selected for new live behavior.
    case legacyRoadV1
    case startReturnRoadV1
    case road5K10KV1
    case roadHalfMarathonV1
    case roadMarathonV1
}

enum RunningPlanningConflictCode: String, Codable, CaseIterable, Sendable {
    case missingLegacyBridge
    case invalidCalendar
    case invalidLegacyInput
    case unsupportedDiscipline
    case unsupportedSurface
    case unsupportedDistance
    case unsupportedEventConstraint
    case unsupportedAvailabilityConstraint
    case missingRaceDistance
    case missingPrimaryEvent
    case multiplePrimaryEvents
    case invalidAvailability
    case availabilityMismatch
    case preferenceMismatch
    case displayUnitMismatch
    case eventMismatch
    case intensityRequiresMoreDays
    case primaryEventInPast
    case goalMismatch
    case activeRestrictionUnsupported
    case policyMismatch
    case trainingDayBudgetExceeded
    case fixedDateCollision
    case noFeasibleSchedule
    case terminalEventConflict
    case continuityGateRequired
    case rulesetMismatch
    case validationFailed
    case selfCoachedProtected
}

struct RunningPlanningConflict: Codable, Equatable, Sendable {
    let code: RunningPlanningConflictCode
    let field: String
    let detail: String
    let alternatives: [String]

    init(_ code: RunningPlanningConflictCode,
         field: String,
         detail: String,
         alternatives: [String] = []) {
        self.code = code
        self.field = field
        self.detail = detail
        self.alternatives = alternatives
    }
}

enum RunningFeasibilityVerdict: String, Codable, CaseIterable, Sendable {
    case onTrack
    case tight
    case tooShort
    case noRace
    case unsupported
}

struct FeasibilityResult: Codable, Equatable, Sendable {
    let verdict: RunningFeasibilityVerdict
    let weeksAvailable: Int?
    let weeksNeeded: Int?
    let recommendedIntensity: PlanIntensity?
    let realisticFinishS: Double?
    let weeklyCapShortfallM: Double?
    let conflicts: [RunningPlanningConflict]
    let headline: String
    let detail: String
    let options: [String]
}

struct BlockIntent: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let phase: PlanPhase
    let firstWeekIndex: Int
    let lastWeekIndex: Int
    let objective: String
    let ruleIDs: [RunningRuleID]
}

struct WeeklyDoseEnvelope: Codable, Equatable, Sendable {
    let weekIndex: Int
    let phase: PlanPhase
    let trainingDistanceM: RunningValueRange?
    let trainingDurationS: RunningValueRange?
    let sessionCount: RunningValueRange
    let longRunDistanceM: RunningValueRange?
    let qualitySessionCount: RunningValueRange
    let strengthSessionCount: RunningValueRange
}

struct PolicyWeekContext: Sendable {
    let request: PlanningRequest
    let generatedPlan: GeneratedPlan
    let weekIndex: Int
}

enum BlockExitState: String, Codable, CaseIterable, Sendable {
    case hold
    case advance
    case complete
    case blocked
}

struct BlockExitContext: Sendable {
    let request: PlanningRequest
    let block: BlockIntent
    let completedSessionCount: Int
    let plannedSessionCount: Int
    let evaluatedAt: Date
}

struct BlockExitDecision: Codable, Equatable, Sendable {
    let state: BlockExitState
    let reasons: [String]
    let ruleIDs: [RunningRuleID]
    let limitations: Set<RunningEvidenceLimitation>
}

/// Event-specific policies choose content and progression. Shared adapters own normalization,
/// scheduling, guards, rounding, validation, persistence and rollback.
protocol RunningPolicy: Sendable {
    var id: RunningPolicyID { get }
    var version: Int { get }
    func feasibility(for request: PlanningRequest) -> FeasibilityResult
    func blockMap(for request: PlanningRequest) -> [BlockIntent]
    func weeklyDose(for context: PolicyWeekContext) -> WeeklyDoseEnvelope
    func sessionIntents(for context: PolicyWeekContext) -> [SessionIntent]
    func exitDecision(for context: BlockExitContext) -> BlockExitDecision
}
