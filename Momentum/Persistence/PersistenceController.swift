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
    ]

    private init(inMemory: Bool = false) {
        let schema = Schema(Self.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        ExerciseLibrarySeed.seedIfNeeded(into: container.mainContext)
        #if DEBUG
        DemoSeed.seedIfRequested(container.mainContext)
        #endif
    }

    /// In-memory container for tests and previews.
    static func inMemory() -> PersistenceController { PersistenceController(inMemory: true) }
}
