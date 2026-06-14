import Foundation
import SwiftData
import Observation

/// Drives a **timed** activity capture (PRD §8.7 extension) — tennis, yoga, and the rest of the
/// "other sports" that have neither a GPS route nor logged sets. A plain stopwatch with pause/resume,
/// durable by contract: the `Workout` is persisted the instant recording starts (so a force-quit
/// never loses it) and its active duration is checkpointed every tick. No `gps`/`strength` payload.
@MainActor
@Observable
final class TimedTrackingViewModel {
    let type: WorkoutType

    private let context: ModelContext
    private var workoutPID: PersistentIdentifier?
    private(set) var workoutId: UUID?

    private(set) var elapsed: TimeInterval = 0
    private(set) var isPaused = false

    private var priorActive: TimeInterval = 0   // active time banked from completed run segments
    private var activeSince: Date?              // start of the current running segment (nil = paused)
    private var ticker: Task<Void, Never>?

    init(type: WorkoutType, container: ModelContainer) {
        self.type = type
        self.context = ModelContext(container)
    }

    func start() {
        guard workoutPID == nil else { return }
        let workout = Workout()
        workout.type = type
        workout.startedAt = Date()
        context.insert(workout)
        try? context.save()
        workoutPID = workout.persistentModelID
        workoutId = workout.id
        ActiveWorkoutMarker.set(workout.id)
        activeSince = Date()
        Haptics.success()
        startTicker()
    }

    func togglePause() {
        Haptics.light()
        if isPaused {
            activeSince = Date()
            isPaused = false
        } else {
            bankActive()
            activeSince = nil
            isPaused = true
            writeDuration()
        }
    }

    @discardableResult
    func finish() -> UUID? {
        bankActive()
        activeSince = nil
        ticker?.cancel(); ticker = nil
        writeDuration()
        ActiveWorkoutMarker.clear()
        return workoutId
    }

    /// Throw the recording away (explicit user action) — deletes the persisted workout.
    @discardableResult
    func discard() -> UUID? {
        ticker?.cancel(); ticker = nil
        if let pid = workoutPID, let w = context.model(for: pid) as? Workout {
            context.delete(w)
            try? context.save()
        }
        ActiveWorkoutMarker.clear()
        workoutId = nil
        return nil
    }

    // MARK: Internals

    private func currentActive() -> TimeInterval {
        priorActive + (activeSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func bankActive() {
        if let since = activeSince {
            priorActive += Date().timeIntervalSince(since)
            activeSince = Date()
        }
    }

    private func startTicker() {
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsed = self.currentActive()
                self.writeDuration()      // cheap durability checkpoint (one field)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func writeDuration() {
        guard let pid = workoutPID, let w = context.model(for: pid) as? Workout else { return }
        let dur = currentActive()
        w.durationS = dur
        w.elapsedS = dur
        try? context.save()
    }
}
