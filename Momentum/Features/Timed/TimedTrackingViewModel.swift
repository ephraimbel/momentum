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

    // Voice coach (PRD §4.10, Pro). A stopwatch sport has no splits to call, so the clock IS the
    // coaching: what is recording, the time as it passes, and the total at the end. nil when not
    // entitled or muted, so the capture never depends on it.
    private let voice: (any VoiceCoachServing)?
    private var coach: TimedCoach
    private var gate = CoachCueGate()

    /// A milestone that arrived inside the spacing window and is owed once it closes.
    private var pendingCueTask: Task<Void, Never>?

    private var priorActive: TimeInterval = 0   // active time banked from completed run segments
    private var activeSince: Date?              // start of the current running segment (nil = paused)
    private var ticker: Task<Void, Never>?

    init(type: WorkoutType, container: ModelContainer, voice: (any VoiceCoachServing)? = nil) {
        self.type = type
        self.context = ModelContext(container)
        self.voice = voice
        self.coach = TimedCoach(type: type)
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
        voice?.prepare()
        cue(coach.intro())
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
        if isPaused { pendingCueTask?.cancel(); pendingCueTask = nil; gate.clearPending() }
        cue(CoachCueGate.Line(text: isPaused ? CoachingCueBuilder.paused() : CoachingCueBuilder.resumed(),
                              priority: .transition))
    }

    @discardableResult
    func finish() -> UUID? {
        bankActive()
        activeSince = nil
        ticker?.cancel(); ticker = nil
        pendingCueTask?.cancel(); pendingCueTask = nil
        gate.clearPending()
        writeDuration()
        ActiveWorkoutMarker.clear()
        // The closing line is the only summary a stopwatch sport gets aloud, so it is allowed to
        // finish speaking: `stop()` here would cut it off mid-number.
        cue(coach.complete(elapsedS: currentActive()))
        return workoutId
    }

    /// Throw the recording away (explicit user action) — deletes the persisted workout.
    @discardableResult
    func discard() -> UUID? {
        ticker?.cancel(); ticker = nil
        pendingCueTask?.cancel(); pendingCueTask = nil
        voice?.stop()
        if let pid = workoutPID, let w = context.model(for: pid) as? Workout {
            context.delete(w)
            try? context.save()
        }
        ActiveWorkoutMarker.clear()
        workoutId = nil
        return nil
    }

    // MARK: Coach cues

    /// Route a line to the voice through the same spacing gate the run coach uses, so a pause
    /// landing on a clock call never talks over it. There is no on-screen coach line here: the
    /// stopwatch is already the whole screen.
    ///
    /// A parked line is owed, not dropped: the clock is called every five to fifteen minutes, and
    /// swallowing the one that happens to land within twelve seconds of a pause would lose the
    /// only thing a stopwatch sport ever says.
    private func cue(_ line: CoachCueGate.Line) {
        guard voice != nil else { return }
        switch gate.admit(line, at: currentActive()) {
        case .deliver:
            pendingCueTask?.cancel(); pendingCueTask = nil
            voice?.announce(line.text)
        case let .park(delayS):
            pendingCueTask?.cancel()
            pendingCueTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delayS))
                guard !Task.isCancelled, let self, !self.isPaused else { return }
                if let owed = self.gate.takePending(at: self.currentActive()) {
                    self.voice?.announce(owed.text)
                }
            }
        case .drop:
            break
        }
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
                if let line = self.coach.tick(elapsedS: self.elapsed, paused: self.isPaused) {
                    self.cue(line)
                }
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
