import Foundation
import SwiftData

/// Cold-launch recovery (PRD §8.3/§8.4). If a workout was being captured when the app died, the
/// `ActiveWorkoutMarker` still points at it — surface it so the UI can offer "Resume?".
@MainActor
enum WorkoutRecovery {
    /// The unfinished workout to offer resuming, if any. Only runs a fetch when a crash marker
    /// actually exists (the rare post-crash path), so the normal launch does no extra work.
    /// Filters in memory to avoid a non-Sendable `SortDescriptor`/`#Predicate` keypath.
    static func pendingWorkout(in context: ModelContext) -> Workout? {
        guard let id = ActiveWorkoutMarker.pendingID else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        return all.first { $0.id == id }
    }

    /// Discard a pending workout the user chooses not to resume (an explicit user action —
    /// distinct from the never-destroy-on-edit rule). Clears the marker either way.
    static func discardPending(in context: ModelContext) {
        if let workout = pendingWorkout(in: context) {
            context.delete(workout)
            try? context.save()
        }
        ActiveWorkoutMarker.clear()
    }
}
