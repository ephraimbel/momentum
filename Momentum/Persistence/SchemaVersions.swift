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
/// Declaring V1 now costs nothing and buys the ability to name a V2. **The version identifier must
/// stay `1.0.0`**: an unversioned `Schema(_:)` already reports itself as 1.0.0, so this pins the
/// existing store's identity rather than announcing a new one, and shipping builds open exactly as
/// they did before (verified against a store written by the previous build).
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// Every persisted model type. Keep in sync with `Models/`.
    ///
    /// This list is the canonical one — `PersistenceController.models` now forwards here. It lives on
    /// the versioned schema because that is what a V2 will need to diff against: the next schema
    /// declares its own list, and the two together are what makes a `MigrationStage` expressible.
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
}

/// The migration plan. One schema, no stages — there is nothing to migrate yet, and that is the
/// point: the plan exists so the day a change is NOT additive, the fix is to add `SchemaV2` and a
/// stage here, rather than to discover at ship time that there was never anywhere to put one.
///
/// **Adding V2**: declare `SchemaV2` with the new model list, append it to `schemas` (ordered
/// oldest → newest), and add a `MigrationStage` — `.lightweight` when the change is still additive,
/// `.custom` when data has to be moved. `PersistenceController` already passes this plan to the
/// container, so nothing else changes.
enum MomentumMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
