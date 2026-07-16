import Foundation
import SwiftData

/// Owns the SwiftData `ModelContainer` — the **local source of truth** and the only singleton
/// in the app (PRD §17). Schema is versioned (`SchemaV1`) for lightweight migration (§8.7).
@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer

    /// All persisted model types. Keep in sync with `Models/`.
    static let models: [any PersistentModel.Type] = [
        UserProfile.self,
        Workout.self, WorkoutPhoto.self, GPSDetail.self, LocationSample.self, Split.self, HeartRateSample.self,
        StrengthSession.self, WorkoutExercise.self, SetEntry.self,
        Exercise.self,
        TrainingPlan.self, PlannedSession.self, PlannedExercise.self,
        PersonalRecord.self,
        AthleteModel.self, MemoryNote.self, FitnessSnapshot.self,
        ChatMessage.self,
        CoachingEvent.self,
        AppNotification.self,
        DailyCheckin.self,
        Meal.self,
    ]

    private init(inMemory: Bool = false) {
        let schema = Schema(Self.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // A failed lightweight migration or a corrupt store must NOT become a permanent
            // launch crash-loop escapable only by delete-and-reinstall. Reset the on-disk store
            // once and retry — recreating an empty store is strictly better than an unrecoverable
            // crash (and, for a first release with no migration history, essentially can't lose real
            // data). In-memory configs have no file to reset, so a failure there is genuinely fatal.
            if !inMemory { Self.destroyStore(at: config.url) }
            do {
                container = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create ModelContainer even after a store reset: \(error)")
            }
        }
        ExerciseLibrarySeed.seedIfNeeded(into: container.mainContext)
        #if DEBUG
        DemoSeed.seedIfRequested(container.mainContext)
        #endif
    }

    /// In-memory container for tests and previews.
    static func inMemory() -> PersistenceController { PersistenceController(inMemory: true) }

    /// Delete the SwiftData store and its SQLite sidecars so a corrupt or unmigratable store can be
    /// recreated empty on the retry instead of crash-looping the app on launch.
    private static func destroyStore(at url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        for file in [name, "\(name)-wal", "\(name)-shm"] {
            try? fm.removeItem(at: dir.appendingPathComponent(file))
        }
    }
}
