import Foundation
import SwiftData

/// A plan that is not the current one (2026-09-07, docs/PLAN-AND-FUEL-UPGRADE.md §3.1): a draft the
/// athlete is thinking about, an upcoming plan waiting for its start date, or a previous plan that
/// finished or was replaced. Kept as a scalar-keyed sidecar so the released `TrainingPlan` graph is
/// never touched and the invariant every engine already assumes, exactly one `TrainingPlan` row
/// reachable only through `UserProfile.plan`, keeps holding.
///
/// What a record carries depends on its status:
/// - `draft` / `upcoming` hold a `PlanBlueprint` (`blueprintData`) and a cached `PlanPreview`
///   (`previewData`). They are inputs, never sessions, so nothing about them can leak into the
///   current plan, and a draft cannot start on its own because nothing reads its date.
/// - `completed` / `incomplete` also hold the plan's final state (`snapshotData`, the
///   `CoachUndo.Snapshot.PlanState` format) so the athlete can look back at what the block was.
///
/// The `Workout` rows are never part of a record. Switching or retiring a plan never deletes or
/// rewrites workouts; only the plan's own ledger of sessions moves here.
@Model
final class PlanShelfRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var profileID: UUID = UUID()
    /// `PlanShelfStatus` raw value.
    var statusRaw: String = PlanShelfStatus.draft.rawValue
    var name: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Upcoming: the day it should start. Draft: an intended day the athlete pencilled in, purely
    /// informational. Previous plans: nil.
    var scheduledStart: Date?
    /// Previous plans: the span the plan was in force.
    var startedAt: Date?
    var endedAt: Date?
    /// `PlanBlueprint` JSON: what to build (drafts, upcoming) or what it was built from (previous).
    var blueprintData: Data = Data()
    /// `PlanPreview` JSON, cached for the cards; rebuilt whenever the blueprint changes.
    var previewData: Data?
    /// Previous plans only: `CoachUndo.Snapshot.PlanState` JSON at retirement.
    @Attribute(.externalStorage) var snapshotData: Data?
    /// The `TrainingPlan.id` this record was (previous plans) — informational, never a relationship.
    var sourcePlanID: UUID?
    var version: Int = 1

    init(id: UUID = UUID(), profileID: UUID, status: PlanShelfStatus, name: String,
         createdAt: Date, blueprintData: Data) {
        self.id = id
        self.profileID = profileID
        self.statusRaw = status.rawValue
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.blueprintData = blueprintData
    }

    var status: PlanShelfStatus {
        get { PlanShelfStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var blueprint: PlanBlueprint? {
        try? JSONDecoder().decode(PlanBlueprint.self, from: blueprintData)
    }

    var preview: PlanPreview? {
        previewData.flatMap { try? JSONDecoder().decode(PlanPreview.self, from: $0) }
    }

    var snapshot: CoachUndo.Snapshot.PlanState? {
        snapshotData.flatMap { try? JSONDecoder().decode(CoachUndo.Snapshot.PlanState.self, from: $0) }
    }

    /// Every record on one athlete's shelf, newest first within each status.
    static func fetch(profileID: UUID, in context: ModelContext) -> [PlanShelfRecord] {
        let descriptor = FetchDescriptor<PlanShelfRecord>(
            predicate: #Predicate { $0.profileID == profileID },
            sortBy: [SortDescriptor(\PlanShelfRecord.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }
}
