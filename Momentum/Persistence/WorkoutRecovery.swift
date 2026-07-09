import Foundation
import SwiftData

/// Cold-launch recovery (PRD §8.3/§8.4). If a workout was being captured when the app died, the
/// `ActiveWorkoutMarker` still points at it. Every sample/set was persisted as it occurred — this
/// is the piece that picks the data back up on the next launch: empty recordings are swept away
/// silently; real ones are finalized so the athlete can keep or discard them ("zero lost workouts").
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

    /// Launch-time sweep. Returns the interrupted workout when there is real data worth keeping
    /// (drives the "found an unfinished workout" prompt); silently deletes an empty husk (e.g. the
    /// app died during the start countdown) and clears the marker either way when there's nothing
    /// to recover.
    static func checkOnLaunch(in context: ModelContext) -> Workout? {
        guard ActiveWorkoutMarker.pendingID != nil else { return nil }
        guard let workout = pendingWorkout(in: context) else {
            ActiveWorkoutMarker.clear()   // marker outlived its workout (e.g. discarded elsewhere)
            return nil
        }
        guard hasContent(workout) else {
            context.delete(workout)
            try? context.save()
            ActiveWorkoutMarker.clear()
            return nil
        }
        return workout
    }

    /// Whether the interrupted recording captured anything a person would want back.
    private static func hasContent(_ workout: Workout) -> Bool {
        if let gps = workout.gps, gps.samples.contains(where: \.accepted) { return true }
        if let strength = workout.strength,
           strength.exercises.contains(where: { $0.sets.contains(where: \.isComplete) }) { return true }
        // A time-only session (location denied / timed workout) that ran for a real interval.
        return workout.durationS >= 60
    }

    /// Close out the interrupted workout from its persisted data — the aggregates `finishWorkout`
    /// would have written. Durations come from evidence (last sample / last logged set), never from
    /// the relaunch clock, so a run killed on Tuesday doesn't "last" until Thursday.
    static func finalizePending(in context: ModelContext) {
        guard let workout = pendingWorkout(in: context) else { ActiveWorkoutMarker.clear(); return }

        if let gps = workout.gps {
            let accepted = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
            if let last = accepted.last {
                let span = last.t.timeIntervalSince(workout.startedAt)
                if span > 0 { workout.durationS = max(workout.durationS, span) }
            }
            // Distance/elevation were checkpointed every 5s while live; derive the average from
            // what actually stuck so the summary math is self-consistent.
            if workout.type.discipline == .cycling {
                gps.avgSpeedMS = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
            } else if gps.distanceM > 0, workout.durationS > 0 {
                gps.avgPaceSPerKm = workout.durationS / (gps.distanceM / 1000)
            }
        }

        if let strength = workout.strength {
            let completed = strength.exercises.flatMap(\.sets).filter(\.isComplete)
            strength.totalSets = completed.count
            strength.totalVolumeKg = completed
                .filter { $0.type == .working }
                .reduce(0) { $0 + (($1.weightKg ?? 0) * Double($1.reps ?? 0)) }
            if let lastSet = completed.compactMap(\.completedAt).max() {
                let span = lastSet.timeIntervalSince(workout.startedAt)
                if span > 0 { workout.durationS = max(workout.durationS, span) }
            } else if workout.durationS == 0 {
                // Legacy rows without timestamps: a conservative floor beats a 0:00 ghost.
                workout.durationS = Double(completed.count) * 90
            }
        }

        workout.elapsedS = max(workout.elapsedS, workout.durationS)
        try? context.save()
        ActiveWorkoutMarker.clear()
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
