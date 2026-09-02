import Foundation
import SwiftData

/// Persistence sidecars for the running planner. They deliberately use stable UUID/string keys
/// instead of relationships to shipped V1 model classes, so adding the running system does not
/// mutate the storage shape of `UserProfile`, `TrainingPlan`, or `PlannedSession`.

@Model
final class RunningSeasonRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var profileID: UUID = UUID()
    var activePlanID: UUID?
    var name: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var statusRaw: String = RunningSeasonStatus.draft.rawValue
    var primaryOutcomeRaw: String = RunningPrimaryOutcome.buildBase.rawValue
    var motivationRaws: [String] = []
    var version: Int = 1
    /// Version of the legacy-to-season adapter that last populated this row. Zero means the row was
    /// created directly from the running domain rather than backfilled.
    var backfillVersion: Int = 0

    init(id: UUID,
         profileID: UUID,
         activePlanID: UUID?,
         name: String,
         createdAt: Date,
         updatedAt: Date,
         statusRaw: String,
         primaryOutcomeRaw: String,
         motivationRaws: [String],
         version: Int = 1,
         backfillVersion: Int = 0) {
        self.id = id
        self.profileID = profileID
        self.activePlanID = activePlanID
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.statusRaw = statusRaw
        self.primaryOutcomeRaw = primaryOutcomeRaw
        self.motivationRaws = Array(Set(motivationRaws)).sorted()
        self.version = version
        self.backfillVersion = backfillVersion
    }
}

@Model
final class RunningEventRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var seasonID: UUID = UUID()
    var name: String = ""
    var date: Date = Date()
    var distanceM: Double?
    var durationS: Double?
    var priorityRaw: String = RunningEventPriority.a.rawValue
    var surfaceRaw: String = RunningEventSurface.road.rawValue
    var ascentM: Double?
    var descentM: Double?
    var altitudeRaw: String = RunningEnvironmentBand.unknown.rawValue
    var technicalityRaw: String = RunningEnvironmentBand.unknown.rawValue
    var climateRaw: String = RunningEnvironmentBand.unknown.rawValue
    var statusRaw: String = RunningEventStatus.planned.rawValue
    var version: Int = 1

    init(id: UUID,
         seasonID: UUID,
         name: String,
         date: Date,
         distanceM: Double?,
         durationS: Double?,
         priorityRaw: String,
         surfaceRaw: String,
         ascentM: Double? = nil,
         descentM: Double? = nil,
         altitudeRaw: String = RunningEnvironmentBand.unknown.rawValue,
         technicalityRaw: String = RunningEnvironmentBand.unknown.rawValue,
         climateRaw: String = RunningEnvironmentBand.unknown.rawValue,
         statusRaw: String = RunningEventStatus.planned.rawValue,
         version: Int = 1) {
        self.id = id
        self.seasonID = seasonID
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.date = date
        self.distanceM = distanceM
        self.durationS = durationS
        self.priorityRaw = priorityRaw
        self.surfaceRaw = surfaceRaw
        self.ascentM = ascentM
        self.descentM = descentM
        self.altitudeRaw = altitudeRaw
        self.technicalityRaw = technicalityRaw
        self.climateRaw = climateRaw
        self.statusRaw = statusRaw
        self.version = version
    }
}

@Model
final class PlanMetadataRecord {
    /// Equal to `planID`. Keeping one stable primary key avoids a second uniqueness mechanism.
    @Attribute(.unique) var id: UUID = UUID()
    var planID: UUID = UUID()
    var seasonID: UUID = UUID()
    var requestID: UUID?
    var plannerVersion: String = ""
    var rulesetID: String = ""
    var policyIDRaw: String?
    var semanticDigest: String = ""
    var createdAt: Date = Date()
    var version: Int = 1
    var isLegacyBackfill: Bool = false

    init(planID: UUID,
         seasonID: UUID,
         requestID: UUID?,
         plannerVersion: String,
         rulesetID: String,
         policyIDRaw: String?,
         semanticDigest: String,
         createdAt: Date,
         version: Int = 1,
         isLegacyBackfill: Bool = false) {
        id = planID
        self.planID = planID
        self.seasonID = seasonID
        self.requestID = requestID
        self.plannerVersion = plannerVersion
        self.rulesetID = rulesetID
        self.policyIDRaw = policyIDRaw
        self.semanticDigest = semanticDigest
        self.createdAt = createdAt
        self.version = version
        self.isLegacyBackfill = isLegacyBackfill
    }
}

@Model
final class PlannedSessionIntentRecord {
    @Attribute(.unique) var id: String = ""
    /// One intent sidecar per persisted planned session.
    @Attribute(.unique) var plannedSessionID: UUID = UUID()
    var planID: UUID = UUID()
    var seasonID: UUID = UUID()
    var intentVersion: Int = 1
    var weekIndex: Int = 0
    var dayOffset: Int = 0
    var stimulusRaw: String = RunningStimulus.unstructured.rawValue
    var sessionClassRaw: String = RunningIntentSessionClass.easy.rawValue
    var progressionLevel: Int = 0
    var hardClassRaw: String = RunningHardClass.none.rawValue
    var primaryTargetRaw: String = RunningTargetKind.completion.rawValue
    var fallbackTargetRaws: [String] = []
    var workDistanceM: Double?
    var workDurationS: Double?
    var workPaceSPerKm: Double?
    var intervalPrescription: String?
    /// Deterministic sorted-key JSON for ordered strength targets; empty array for non-strength.
    var strengthTargetsJSON: Data = Data("[]".utf8)
    var recoveryDistanceM: Double?
    var recoveryDurationS: Double?
    var recoveryModeRaw: String?
    var successLower: Double?
    var successUpper: Double?
    var recoveryCostRaw: String = RunningRecoveryCostBand.unknown.rawValue
    var validSubstitutionIDs: [String] = []
    var minimumCompletedExposures: Int = 0
    var minimumConfidenceRaw: String = RunningEvidenceConfidence.unknown.rawValue
    var purpose: String = ""
    var ruleIDRaws: [String] = []
    var limitationRaws: [String] = []
    var createdAt: Date = Date()

    init(id: String,
         plannedSessionID: UUID,
         planID: UUID,
         seasonID: UUID,
         intentVersion: Int,
         weekIndex: Int,
         dayOffset: Int,
         stimulusRaw: String,
         sessionClassRaw: String,
         progressionLevel: Int,
         hardClassRaw: String,
         primaryTargetRaw: String,
         fallbackTargetRaws: [String],
         workDistanceM: Double?,
         workDurationS: Double?,
         workPaceSPerKm: Double?,
         intervalPrescription: String?,
         strengthTargetsJSON: Data,
         recoveryDistanceM: Double?,
         recoveryDurationS: Double?,
         recoveryModeRaw: String?,
         successLower: Double?,
         successUpper: Double?,
         recoveryCostRaw: String,
         validSubstitutionIDs: [String],
         minimumCompletedExposures: Int,
         minimumConfidenceRaw: String,
         purpose: String,
         ruleIDRaws: [String],
         limitationRaws: [String],
         createdAt: Date) {
        self.id = id
        self.plannedSessionID = plannedSessionID
        self.planID = planID
        self.seasonID = seasonID
        self.intentVersion = intentVersion
        self.weekIndex = weekIndex
        self.dayOffset = dayOffset
        self.stimulusRaw = stimulusRaw
        self.sessionClassRaw = sessionClassRaw
        self.progressionLevel = progressionLevel
        self.hardClassRaw = hardClassRaw
        self.primaryTargetRaw = primaryTargetRaw
        self.fallbackTargetRaws = fallbackTargetRaws
        self.workDistanceM = workDistanceM
        self.workDurationS = workDurationS
        self.workPaceSPerKm = workPaceSPerKm
        self.intervalPrescription = intervalPrescription
        self.strengthTargetsJSON = strengthTargetsJSON
        self.recoveryDistanceM = recoveryDistanceM
        self.recoveryDurationS = recoveryDurationS
        self.recoveryModeRaw = recoveryModeRaw
        self.successLower = successLower
        self.successUpper = successUpper
        self.recoveryCostRaw = recoveryCostRaw
        self.validSubstitutionIDs = validSubstitutionIDs
        self.minimumCompletedExposures = minimumCompletedExposures
        self.minimumConfidenceRaw = minimumConfidenceRaw
        self.purpose = purpose
        self.ruleIDRaws = Array(Set(ruleIDRaws)).sorted()
        self.limitationRaws = Array(Set(limitationRaws)).sorted()
        self.createdAt = createdAt
    }
}

@Model
final class PlanDecisionRecord {
    @Attribute(.unique) var id: UUID = UUID()
    /// Idempotency key: one durable decision for one planning request.
    @Attribute(.unique) var requestID: UUID = UUID()
    var profileID: UUID = UUID()
    var planID: UUID?
    var seasonID: UUID = UUID()
    var decidedAt: Date = Date()
    var triggerRaw: String = RunningPlanningTrigger.shadowEvaluation.rawValue
    var statusRaw: String = RunningDecisionStatus.candidate.rawValue
    var plannerVersion: String = ""
    var rulesetID: String = ""
    var policyIDRaw: String?
    var oldPlanDigest: String?
    var newPlanDigest: String?
    /// Versioned compact structured diff. It must never contain a route, raw Health sample, exact
    /// location, or unrestricted medical note.
    var diffJSON: Data = Data()
    var appliedRuleIDRaws: [String] = []
    var hardConstraintRaws: [String] = []
    var relaxedPreferenceRaws: [String] = []
    var evidenceConfidenceRaws: [String] = []
    var limitationRaws: [String] = []
    var headline: String = ""
    var detail: String = ""
    var athleteResponseRaw: String = "pending"
    var normalizedInputVersion: Int = 1
    /// Compact aggregate/replay input only; never raw sensor/GPS samples or unrestricted notes.
    var normalizedInputJSON: Data = Data()
    var version: Int = 1

    init(id: UUID,
         requestID: UUID,
         profileID: UUID,
         planID: UUID?,
         seasonID: UUID,
         decidedAt: Date,
         triggerRaw: String,
         statusRaw: String,
         plannerVersion: String,
         rulesetID: String,
         policyIDRaw: String?,
         oldPlanDigest: String?,
         newPlanDigest: String?,
         diffJSON: Data,
         appliedRuleIDRaws: [String],
         hardConstraintRaws: [String],
         relaxedPreferenceRaws: [String],
         evidenceConfidenceRaws: [String],
         limitationRaws: [String],
         headline: String,
         detail: String,
         athleteResponseRaw: String = "pending",
         normalizedInputVersion: Int = 1,
         normalizedInputJSON: Data,
         version: Int = 1) {
        self.id = id
        self.requestID = requestID
        self.profileID = profileID
        self.planID = planID
        self.seasonID = seasonID
        self.decidedAt = decidedAt
        self.triggerRaw = triggerRaw
        self.statusRaw = statusRaw
        self.plannerVersion = plannerVersion
        self.rulesetID = rulesetID
        self.policyIDRaw = policyIDRaw
        self.oldPlanDigest = oldPlanDigest
        self.newPlanDigest = newPlanDigest
        self.diffJSON = diffJSON
        self.appliedRuleIDRaws = Array(Set(appliedRuleIDRaws)).sorted()
        self.hardConstraintRaws = Array(Set(hardConstraintRaws)).sorted()
        self.relaxedPreferenceRaws = Array(Set(relaxedPreferenceRaws)).sorted()
        self.evidenceConfidenceRaws = Array(Set(evidenceConfidenceRaws)).sorted()
        self.limitationRaws = Array(Set(limitationRaws)).sorted()
        self.headline = headline
        self.detail = detail
        self.athleteResponseRaw = athleteResponseRaw
        self.normalizedInputVersion = normalizedInputVersion
        self.normalizedInputJSON = normalizedInputJSON
        self.version = version
    }
}
