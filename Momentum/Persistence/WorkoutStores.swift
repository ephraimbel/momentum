import Foundation
import SwiftData

/// Durable persistence sink for cardio capture (PRD §8.3). A `@ModelActor` owning a background
/// `ModelContext`: every accepted fix is written the moment it arrives, so a force-quit loses
/// nothing. Tracks the live workout by `PersistentIdentifier` and sets the recovery marker.
@ModelActor
actor GPSWorkoutStore: GPSWorkoutSink {
    private var workoutID: PersistentIdentifier?
    private var gpsID: PersistentIdentifier?
    private var type: WorkoutType = .run

    func beginWorkout(type: WorkoutType, startedAt: Date) {
        self.type = type
        let workout = Workout()
        workout.type = type
        workout.startedAt = startedAt
        let detail = GPSDetail()
        workout.gps = detail
        modelContext.insert(workout)
        try? modelContext.save()
        workoutID = workout.persistentModelID
        gpsID = detail.persistentModelID
        ActiveWorkoutMarker.set(workout.id)
    }

    func persistSample(_ fix: GPSProcessor.Fix, accepted: Bool) {
        guard let gpsID, let detail = self[gpsID, as: GPSDetail.self] else { return }
        let sample = LocationSample()
        sample.t = fix.t
        sample.lat = fix.lat
        sample.lon = fix.lon
        sample.accuracyM = fix.accuracyM
        sample.altitudeM = fix.altitudeM
        sample.speedMS = fix.speedMS
        sample.accepted = accepted
        detail.samples.append(sample)
        try? modelContext.save()
    }

    func checkpoint(distanceM: Double, durationS: TimeInterval, elevationGainM: Double) {
        guard let gpsID, let detail = self[gpsID, as: GPSDetail.self],
              let workoutID, let workout = self[workoutID, as: Workout.self] else { return }
        detail.distanceM = distanceM
        detail.elevationGainM = elevationGainM
        workout.durationS = durationS
        try? modelContext.save()
    }

    func finishWorkout(distanceM: Double, durationS: TimeInterval, elevationGainM: Double,
                       smoothedPaceSPerKm: Double) {
        guard let gpsID, let detail = self[gpsID, as: GPSDetail.self],
              let workoutID, let workout = self[workoutID, as: Workout.self] else { return }
        detail.distanceM = distanceM
        detail.elevationGainM = elevationGainM
        if type == .ride {
            detail.avgSpeedMS = durationS > 0 ? distanceM / durationS : 0
        } else {
            detail.avgPaceSPerKm = smoothedPaceSPerKm
        }
        workout.durationS = durationS
        workout.elapsedS = durationS
        try? modelContext.save()
        ActiveWorkoutMarker.clear()
    }

    /// Attach the rendered route snapshot (PRD §8.5) to the finished workout's GPS detail.
    func attachSnapshot(_ data: Data) {
        guard let gpsID, let detail = self[gpsID, as: GPSDetail.self] else { return }
        detail.mapSnapshotData = data
        try? modelContext.save()
    }
}

/// Durable persistence sink for strength capture (PRD §8.4). Maps each live exercise row
/// (`rowId`) to its persisted `WorkoutExercise`, and writes each completed set immediately.
/// Rest-timer *notifications* are a separate concern (NotificationService, Phase 1).
@ModelActor
actor StrengthWorkoutStore: StrengthWorkoutSink {
    private var workoutID: PersistentIdentifier?
    private var sessionID: PersistentIdentifier?
    private var rowIDs: [UUID: PersistentIdentifier] = [:]

    func beginWorkout(startedAt: Date) {
        let workout = Workout()
        workout.type = .strength
        workout.startedAt = startedAt
        let session = StrengthSession()
        workout.strength = session
        modelContext.insert(workout)
        try? modelContext.save()
        workoutID = workout.persistentModelID
        sessionID = session.persistentModelID
        ActiveWorkoutMarker.set(workout.id)
    }

    func persistExercise(rowId: UUID, catalogExerciseId: UUID, order: Int, supersetGroup: Int?) {
        guard let sessionID, let session = self[sessionID, as: StrengthSession.self] else { return }
        let row = WorkoutExercise()
        row.order = order
        row.supersetGroup = supersetGroup
        row.exercise = exercise(with: catalogExerciseId)
        session.exercises.append(row)
        try? modelContext.save()
        rowIDs[rowId] = row.persistentModelID
    }

    func persistSetComplete(rowId: UUID, setIndex: Int,
                            weightKg: Double?, reps: Int?, rpe: Double?, type: SetType) {
        guard let rowPID = rowIDs[rowId], let row = self[rowPID, as: WorkoutExercise.self] else { return }
        let set = SetEntry()
        set.index = setIndex
        set.weightKg = weightKg
        set.reps = reps
        set.rpe = rpe
        set.type = type
        set.isComplete = true
        set.restS = row.exercise?.defaultRestS ?? 120
        row.sets.append(set)
        try? modelContext.save()
    }

    func scheduleRest(seconds: Double, exerciseName: String) {
        // Rest-timer local notification is scheduled by NotificationService in Phase 1.
        // The persistence store intentionally does nothing here.
    }

    func finishWorkout(totalVolumeKg: Double, totalSets: Int, durationS: TimeInterval) {
        guard let sessionID, let session = self[sessionID, as: StrengthSession.self],
              let workoutID, let workout = self[workoutID, as: Workout.self] else { return }
        session.totalVolumeKg = totalVolumeKg
        session.totalSets = totalSets
        workout.durationS = durationS
        workout.elapsedS = durationS
        try? modelContext.save()
        ActiveWorkoutMarker.clear()
    }

    /// User discarded: delete the in-progress workout (cascades to its session/exercises/sets) and
    /// clear the recovery marker so nothing lingers.
    func discardWorkout() {
        if let workoutID, let workout = self[workoutID, as: Workout.self] {
            modelContext.delete(workout)
            try? modelContext.save()
        }
        workoutID = nil; sessionID = nil; rowIDs = [:]
        ActiveWorkoutMarker.clear()
    }

    /// Resolve a catalog/custom exercise by its UUID. The library is small (≤ a few hundred),
    /// so an in-memory filter avoids a non-Sendable `#Predicate` keypath under strict concurrency.
    private func exercise(with id: UUID) -> Exercise? {
        let all = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        return all.first { $0.id == id }
    }
}
