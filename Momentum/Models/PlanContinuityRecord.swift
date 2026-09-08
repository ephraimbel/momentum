import Foundation
import SwiftData

/// V8 additive storage. Athlete-wide restrictions survive replacing the active plan.
/// The cloud journal is device-local; its revision is never part of the uploaded snapshot.
@Model
final class PlanContinuityRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var profileID: UUID = UUID()
    var illnessData: Data?
    /// Volume before an illness interruption must not inflate a returning athlete's baseline.
    var trainingEvidenceFrom: Date?
    var cloudOwnerID: UUID?
    var cloudRevision: Int = 0
    var syncedFingerprint: String?
    var pendingOperationID: UUID?
    @Attribute(.externalStorage) var pendingSnapshot: Data?
    @Attribute(.externalStorage) var conflictingSnapshot: Data?
    var conflictingRevision: Int?
    @Attribute(.externalStorage) var preservedLocalSnapshot: Data?
    var lastSyncedAt: Date?

    init(profileID: UUID) { id = profileID; self.profileID = profileID }

    static func fetch(profileID: UUID, in context: ModelContext) -> PlanContinuityRecord? {
        guard context.container.schema.entities.contains(where: { $0.name == "PlanContinuityRecord" }) else { return nil }
        var query = FetchDescriptor<PlanContinuityRecord>(predicate: #Predicate { $0.profileID == profileID })
        query.fetchLimit = 1
        return (try? context.fetch(query))?.first
    }
    static func upsert(profileID: UUID, in context: ModelContext) -> PlanContinuityRecord {
        if let record = fetch(profileID: profileID, in: context) { return record }
        let record = PlanContinuityRecord(profileID: profileID)
        context.insert(record)
        return record
    }
}

extension UserProfile {
    var continuity: PlanContinuityRecord? {
        modelContext.flatMap { PlanContinuityRecord.fetch(profileID: id, in: $0) }
    }
}
