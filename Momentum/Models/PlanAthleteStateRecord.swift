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

/// V6 bookkeeping lives outside the released TrainingPlan graph so older schemas keep their
/// checksums. Scalar plan IDs only; writes participate in the caller's save/rollback transaction.
@Model
final class PlanCoachingStateRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var planID: UUID = UUID()
    var pauseShiftedDates: [String: Date] = [:]
    var pendingP5kWorkoutID: UUID?
    var paceEvidenceDates: [String: Date] = [:]

    init(planID: UUID) { id = planID; self.planID = planID }

    static func fetch(planID: UUID, in context: ModelContext) -> PlanCoachingStateRecord? {
        var query = FetchDescriptor<PlanCoachingStateRecord>(predicate: #Predicate { $0.planID == planID })
        query.fetchLimit = 1
        return (try? context.fetch(query))?.first
    }

    static func upsert(planID: UUID, in context: ModelContext) -> PlanCoachingStateRecord {
        if let record = fetch(planID: planID, in: context) { return record }
        let record = PlanCoachingStateRecord(planID: planID)
        context.insert(record)
        return record
    }
}

extension TrainingPlan {
    /// Read-only lookup. Creating a plan or taking a signature never inserts bookkeeping rows.
    var coachingState: PlanCoachingStateRecord? {
        modelContext.flatMap { PlanCoachingStateRecord.fetch(planID: id, in: $0) }
    }
}

/// V7: explicit athlete preferences, separate from the released profile schema.
@Model
final class PlanPreferencesRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var profileID: UUID = UUID()
    var regularRunLimitS: Double?
    var longRunLimitS: Double?
    var benchmarkDistanceM: Double?
    var benchmarkTimeS: Double?
    var benchmarkPerformedAt: Date?
    var benchmarkRecordedAt: Date?

    init(profileID: UUID) { id = profileID; self.profileID = profileID }

    static func fetch(profileID: UUID, in context: ModelContext) -> PlanPreferencesRecord? {
        var query = FetchDescriptor<PlanPreferencesRecord>(predicate: #Predicate { $0.profileID == profileID })
        query.fetchLimit = 1
        return (try? context.fetch(query))?.first
    }
    static func upsert(profileID: UUID, in context: ModelContext) -> PlanPreferencesRecord {
        if let record = fetch(profileID: profileID, in: context) { return record }
        let record = PlanPreferencesRecord(profileID: profileID)
        context.insert(record)
        return record
    }
}

extension UserProfile {
    var planPreferences: PlanPreferencesRecord? {
        modelContext.flatMap { PlanPreferencesRecord.fetch(profileID: id, in: $0) }
    }
}

/// V9: dates explicit current-fitness answers without changing the released profile shape.
@Model
final class PlanFitnessDeclarationRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var profileID: UUID = UUID()
    var declaredAt: Date = Date()
    init(profileID: UUID, declaredAt: Date) {
        id = profileID; self.profileID = profileID; self.declaredAt = declaredAt
    }
    static func fetch(profileID: UUID, in context: ModelContext) -> PlanFitnessDeclarationRecord? {
        guard context.container.schema.entities.contains(where: { $0.name == "PlanFitnessDeclarationRecord" }) else { return nil }
        var query = FetchDescriptor<PlanFitnessDeclarationRecord>(predicate: #Predicate { $0.profileID == profileID })
        query.fetchLimit = 1
        return (try? context.fetch(query))?.first
    }
    static func set(_ date: Date?, for profile: UserProfile, in context: ModelContext) {
        guard context.container.schema.entities.contains(where: { $0.name == "PlanFitnessDeclarationRecord" }) else { return }
        let existing = fetch(profileID: profile.id, in: context)
        if let date {
            if let existing { existing.declaredAt = date }
            else { context.insert(PlanFitnessDeclarationRecord(profileID: profile.id, declaredAt: date)) }
        } else if let existing { context.delete(existing) }
    }
}

extension UserProfile {
    var fitnessDeclaredAt: Date? {
        modelContext.flatMap { PlanFitnessDeclarationRecord.fetch(profileID: id, in: $0)?.declaredAt }
    }
}
