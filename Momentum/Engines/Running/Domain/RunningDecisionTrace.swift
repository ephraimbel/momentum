import Foundation

enum RunningHardConstraint: String, Codable, CaseIterable, Hashable, Sendable {
    case supportedRoadPopulation
    case onePrimaryOutcome
    case availabilityBudget
    case fixedCalendar
    case noTrainingAfterTerminalRace
    case reductionOnlyLoadGuard
    case lowerStrengthRecoverySpacing
    case activeRestriction
    case selfCoachedOwnership
    case validatedBeforeCommit
}

enum RunningRelaxedPreference: String, Codable, CaseIterable, Hashable, Sendable {
    case preferredWeekday
    case learnedAvoidWeekday
    case existingPlanPlacement
    case evenRecoverySpacing
    case requestedIntensityTier
    case requestedStrengthSplit
    case sessionTimeCeilingForLongRun
}

enum RunningDecisionStatus: String, Codable, CaseIterable, Sendable {
    case candidate
    /// A candidate that passed the persistence boundary and is durably active (or was active before
    /// a later replacement). Traces are authored as `.candidate`; only `PlanStore` may record this.
    case committed
    case protected
    case conflict
}

struct RunningDecisionTrace: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let requestID: UUID
    let status: RunningDecisionStatus
    let plannerVersion: String
    let rulesetID: String
    let policyID: RunningPolicyID?
    let appliedRuleIDs: [RunningRuleID]
    let hardConstraints: Set<RunningHardConstraint>
    let relaxedPreferences: Set<RunningRelaxedPreference>
    let evidence: [RunningEvidenceSummary]
    let evidenceLimitations: Set<RunningEvidenceLimitation>
    let legacyExceptions: [LegacyPlanExceptionCode]
    let validationCodes: [PlanValidationCode]
    let headline: String
    let detail: String

    /// Trace integrity is checked before a candidate is accepted. Exact prescriptions remain local;
    /// only coarse categories may enter product analytics.
    func unknownRuleIDs(in registry: RunningRuleRegistry) -> [RunningRuleID] {
        appliedRuleIDs.filter { registry[$0] == nil }
    }
}
