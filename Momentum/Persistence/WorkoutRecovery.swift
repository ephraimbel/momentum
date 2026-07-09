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

    /// Roll a still-recording shell up into a finished workout using only its durably-persisted data,
    /// so a recovered run saves *identically* to one the athlete finished by hand — then clear the
    /// marker. Everything this needs was written live: GPS samples + the ≤5s-old distance/duration
    /// checkpoint, or each completed set. The live `finish()` never ran, so it fills the gaps it would
    /// have: overall averages, the route thumbnail, calories, and the strength rollups.
    static func finalize(_ workout: Workout, bodyMassKg: Double?, in context: ModelContext) async {
        workout.elapsedS = workout.durationS

        if let gps = workout.gps {
            // Overall averages off the distance + moving time the engine checkpointed live.
            if workout.type.discipline == .cycling {
                gps.avgSpeedMS = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
            } else if gps.distanceM > 0, workout.durationS > 0 {
                gps.avgPaceSPerKm = workout.durationS / (gps.distanceM / 1000)
            }
            // Render the route thumbnail the finish path would have produced (unless one already exists).
            if gps.mapSnapshotData == nil {
                let coords = gps.routeCoordinates(type: workout.type)
                if coords.count > 1, let data = await RouteSnapshotter.snapshot(coordinates: coords) {
                    gps.mapSnapshotData = data
                }
            }
        }

        if let strength = workout.strength {
            // Recompute the rollups from the persisted working sets (PRD §22 — working sets only).
            let working = strength.exercises.flatMap(\.sets).filter { $0.isComplete && $0.type == .working }
            strength.totalSets = working.count
            strength.totalVolumeKg = working.reduce(0) { acc, s in
                guard let w = s.weightKg, let r = s.reps else { return acc }
                return acc + StrengthMath.setVolume(weightKg: w, reps: r)
            }
        }

        workout.calories = CalorieEstimator.kcal(for: workout, bodyMassKg: bodyMassKg)
        try? context.save()
        ActiveWorkoutMarker.clear()
    }
}
