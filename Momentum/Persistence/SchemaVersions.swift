import Foundation
import SwiftData

/// The store's **versioned schema**, declared 2026-08-21.
///
/// Until now there was none, and `PersistenceController` said so plainly: the tree relied on every
/// change being additive so SwiftData's implicit lightweight migration could open an older store.
/// That discipline held, but it is only a discipline — the first rename, retype, or deletion would
/// fail to open every shipped athlete's store, and the failure path is `quarantineStore`: the app
/// relaunches empty and the training history, while recoverable by hand, is gone from the app. A
/// data-loss event for the whole install base, reachable by one ordinary-looking property edit.
///
/// **The version identifier must stay `1.0.0`**: an unversioned `Schema(_:)` already reports itself
/// as 1.0.0, so this pins the released store's identity rather than announcing a new one.
///
/// A historical schema is a byte-level contract, not a list of whatever today's model classes look
/// like. Most V1 types below still use their unchanged production class. `AppNotification` is the
/// first model whose stored shape changed after build 36, so V1 owns a frozen nested snapshot while
/// V2 uses the live class. If another persisted V1 type changes, snapshot its released shape here
/// before editing the live class; the archived-store test will reject an accidental mutation.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// Exact build-36 shape. Never append current-only models or point a changed entry back at its
    /// live type; add those to the next schema instead.
    static var models: [any PersistentModel.Type] {
        [
            UserProfile.self,
            Workout.self, WorkoutPhoto.self, GPSDetail.self, LocationSample.self, Split.self, HeartRateSample.self,
            StrengthSession.self, WorkoutExercise.self, SetEntry.self,
            Exercise.self,
            TrainingPlan.self, PlannedSession.self, PlannedExercise.self,
            PersonalRecord.self,
            SavedRoute.self,
            EarnedAward.self,
            AthleteModel.self, MemoryNote.self, FitnessSnapshot.self,
            ChatMessage.self,
            CoachingEvent.self,
            AppNotification.self,
            DailyCheckin.self,
            Meal.self,
        ]
    }

    /// Frozen copy of the build-36 entity. The class name intentionally remains `AppNotification`:
    /// SwiftData/Core Data uses that entity name to infer the lightweight V1 → V2 field addition.
    @Model
    final class AppNotification {
        var id: UUID = UUID()
        var date: Date = Date()
        var kindRaw: String = "system"
        var title: String = ""
        var body: String = ""
        var read: Bool = false
        var dedupeToken: String?

        init() {}
    }
}

/// Release 1 of the running planner adds only isolated, scalar-ID sidecar tables. No V1 model class
/// changes shape and no new relationship points into the released object graph. That makes the
/// migration genuinely additive: old plan/workout rows are not rewritten, and rollback of planner
/// behavior never requires a store down-migration.
enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            UserProfile.self,
            Workout.self, WorkoutPhoto.self, GPSDetail.self, LocationSample.self, Split.self, HeartRateSample.self,
            StrengthSession.self, WorkoutExercise.self, SetEntry.self,
            Exercise.self,
            TrainingPlan.self, PlannedSession.self, PlannedExercise.self,
            PersonalRecord.self,
            SavedRoute.self,
            EarnedAward.self,
            AthleteModel.self, MemoryNote.self, FitnessSnapshot.self,
            ChatMessage.self,
            CoachingEvent.self,
            AppNotification.self,
            DailyCheckin.self,
            Meal.self,
            RunningSeasonRecord.self,
            RunningEventRecord.self,
            PlanMetadataRecord.self,
            PlannedSessionIntentRecord.self,
            PlanDecisionRecord.self,
        ]
    }
}

/// Ordered oldest → newest. The V1 → V2 path is covered by an on-disk fixture that verifies the
/// completed-plan/workout relationship graph, GPS samples, external photo data, and athlete memory
/// before and after the sidecar tables are written.
enum MomentumMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
    }
}
