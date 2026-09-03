import Foundation
import SwiftData

/// The athlete state a plan was built with (`AthleteStateEngine`, 2026-09-03), as a sidecar keyed
/// by the plan's id — never a field on `TrainingPlan`, whose released shape is a byte-level
/// contract (`SchemaVersions.swift`): adding a property there would orphan every shipped store.
///
/// Holds the observed threshold pace the steady family is anchored on (with how it was read and
/// how sure the read is), the personal Riegel exponent behind race predictions, and the durability
/// read that shaped long-run growth. Scalar ids only, like the other running sidecars, so the
/// migration that adds it is genuinely additive and the plan graph is never rewritten.
@Model
final class PlanAthleteStateRecord {
    /// Equal to `planID`, so one plan has at most one record.
    @Attribute(.unique) var id: UUID = UUID()
    var planID: UUID = UUID()
    var thresholdSPerKm: Double?
    var thresholdMethod: String?        // RunningThresholdMethod raw value
    var thresholdConfidence: String?    // RunningEvidenceConfidence raw value
    var thresholdObservedAt: Date?
    var riegelExponent: Double?
    var durabilitySignal: String?       // DurabilitySignal raw value
    var computedAt: Date = Date()
    /// Last applied threshold sharpening — the same ≤1/week cap `lastRecalibratedAt` puts on the 5K.
    var lastThresholdRecalibratedAt: Date?

    init(planID: UUID) {
        id = planID
        self.planID = planID
    }

    var durability: DurabilitySignal? { durabilitySignal.flatMap(DurabilitySignal.init(rawValue:)) }
    var method: RunningThresholdMethod? { thresholdMethod.flatMap(RunningThresholdMethod.init(rawValue:)) }
    var confidence: RunningEvidenceConfidence? { thresholdConfidence.flatMap(RunningEvidenceConfidence.init(rawValue:)) }

    /// The record for a plan, if one was written.
    static func fetch(planID: UUID, in context: ModelContext) -> PlanAthleteStateRecord? {
        var descriptor = FetchDescriptor<PlanAthleteStateRecord>(predicate: #Predicate { $0.planID == planID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The record for a plan, created if missing. Insert only — the caller owns the save.
    static func upsert(planID: UUID, in context: ModelContext) -> PlanAthleteStateRecord {
        if let existing = fetch(planID: planID, in: context) { return existing }
        let record = PlanAthleteStateRecord(planID: planID)
        context.insert(record)
        return record
    }

    /// Drop the record a replaced plan left behind, so a rebuilt plan never inherits a stale read.
    static func remove(planID: UUID, in context: ModelContext) {
        if let record = fetch(planID: planID, in: context) { context.delete(record) }
    }
}
