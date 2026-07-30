import Foundation

/// Persistence sink for the GPS engine. Phase 1 backs this with SwiftData (`GPSDetail`/
/// `LocationSample`), persisting each accepted sample immediately and checkpointing aggregates
/// every 5s (PRD §8.3 durability). A no-op default keeps the engine testable in isolation.
protocol GPSWorkoutSink: Sendable {
    /// Create the durable `Workout` + `GPSDetail` and mark it the active (recoverable) workout.
    func beginWorkout(type: WorkoutType, startedAt: Date) async
    /// Persist a single fix immediately (the durability guarantee). `pausedSpan` marks a fix
    /// captured while paused (manual or auto) — the engine accrued nothing for it, so readers
    /// must skip both its metres and its seconds.
    func persistSample(_ fix: GPSProcessor.Fix, accepted: Bool, pausedSpan: Bool) async
    /// Update rolled-up aggregates (every ~5s).
    func checkpoint(distanceM: Double, durationS: TimeInterval, elevationGainM: Double) async
    /// Finalize aggregates and clear the active-workout marker. `durationS` is MOVING time (what the
    /// athlete sees and what every pace is computed against); `elapsedS` is wall time from start to
    /// finish, pauses included — the window every Health read (HR series, time-in-zones, import
    /// overlap) must span.
    /// The live EMA is deliberately NOT a parameter. It was one, it went unused-but-passed, and the
    /// store persisted it as the workout's average pace. An argument nobody has to justify is how
    /// that survived — so the value simply cannot reach persistence any more.
    func finishWorkout(distanceM: Double, durationS: TimeInterval, elapsedS: TimeInterval,
                       elevationGainM: Double) async
}

struct NoopGPSWorkoutSink: GPSWorkoutSink {
    func beginWorkout(type: WorkoutType, startedAt: Date) async {}
    func persistSample(_ fix: GPSProcessor.Fix, accepted: Bool, pausedSpan: Bool) async {}
    func checkpoint(distanceM: Double, durationS: TimeInterval, elevationGainM: Double) async {}
    /// The live EMA is deliberately NOT a parameter. It was one, it went unused-but-passed, and the
    /// store persisted it as the workout's average pace. An argument nobody has to justify is how
    /// that survived — so the value simply cannot reach persistence any more.
    func finishWorkout(distanceM: Double, durationS: TimeInterval, elapsedS: TimeInterval,
                       elevationGainM: Double) async {}
}

/// Cardio capture engine (PRD §8.3). A strict state machine over a pure `GPSProcessor`.
/// Durable by contract: every accepted sample is persisted via the sink as it arrives.
actor GPSTrackingEngine {

    enum State: String, Equatable, Sendable {
        case idle, acquiring, tracking, autoPaused, paused, gpsLost, saving, summary, recovered
    }

    struct Coordinate: Sendable, Equatable { let lat: Double; let lon: Double }

    /// One-hop snapshot for the view model (avoids many cross-actor reads per frame).
    struct LiveSnapshot: Sendable {
        let state: State
        let distanceM: Double
        let smoothedPaceSPerKm: Double
        let movingTimeS: TimeInterval
        let elevationGainM: Double
        let route: [Coordinate]
        /// The latest Kalman-corrected position — fresher than `route.last` (which only advances
        /// past the 2 m move gate). Drives the on-map puck so the dot, the camera, and the trace
        /// all follow the SAME filtered track: a rejected GPS spike can't teleport any of them.
        let tip: Coordinate?
    }

    enum Const {
        static let checkpointIntervalS = 5.0
        static let liveActivityUpdateS = 3.0
        static let gpsLostTimeoutS = 8.0   // no accepted fix for this long → GPSLost (keep timing)
        static let maxFixAgeS = 10.0       // drop fixes older than this (e.g. a cached background fix)
    }

    let type: WorkoutType
    private(set) var state: State = .idle
    private var processor: GPSProcessor
    private let sink: GPSWorkoutSink
    /// Accepted coordinates for the live route polyline.
    private(set) var route: [Coordinate] = []

    private var startedAt: Date?
    private var lastCheckpoint: Date?
    /// Accumulated *moving* time (excludes paused spans).
    private(set) var movingTimeS: TimeInterval = 0
    private var lastMovingMark: Date?
    /// A manual Resume (from either a manual or an *auto* pause) suppresses auto-pause until the athlete
    /// actually moves again — so Resume always works, even standing still, and never re-auto-pauses on
    /// the very next stationary fix. Cleared the moment real movement is detected.
    private var autoPauseSuppressed = false

    init(type: WorkoutType, sink: GPSWorkoutSink = NoopGPSWorkoutSink()) {
        self.type = type
        self.processor = GPSProcessor(config: .forType(type))
        self.sink = sink
    }

    // Read-only snapshots for the view model.
    var distanceM: Double { processor.distanceM }
    var smoothedPaceSPerKm: Double { processor.smoothedPaceSPerKm }
    var elevationGainM: Double { processor.elevationGainM }

    func snapshot() -> LiveSnapshot {
        LiveSnapshot(state: state, distanceM: processor.distanceM,
                     smoothedPaceSPerKm: processor.smoothedPaceSPerKm,
                     movingTimeS: movingTimeS, elevationGainM: processor.elevationGainM,
                     route: route,
                     tip: route.isEmpty ? nil : Coordinate(lat: processor.filteredLat,
                                                           lon: processor.filteredLon))
    }

    func begin(now: Date = Date()) async {
        guard state == .idle || state == .recovered else { return }
        state = .acquiring
        startedAt = now
        lastMovingMark = now
        lastCheckpoint = now
        await sink.beginWorkout(type: type, startedAt: now)
    }

    /// Ingest a raw location fix. Drives accept/reject, distance, auto-pause, and persistence.
    func ingest(_ fix: GPSProcessor.Fix, now: Date = Date()) async {
        guard state != .idle, state != .saving, state != .summary else { return }
        // Drop stale fixes (e.g. a cached location delivered on return from background) — a runner
        // covers ~40m in 10s, so an old position would distort both the route and the distance.
        guard now.timeIntervalSince(fix.t) <= Const.maxFixAgeS else { return }

        if state == .acquiring { state = .tracking }

        // Manual pause: the processor stays warm (dot follows, resume can't spike-reject) but accrues
        // no distance, and neither the live route nor the saved one records the paused walk — the
        // sample persists as not-accepted so `RouteReplay` (saved route = accepted samples) skips it
        // too. Resume ≤100m away draws a clean chord; farther splits the trace (LiveSmoother's gap
        // split) — both exactly Strava's pause behavior.
        let manuallyPaused = state == .paused
        // Auto-pause accrues nothing either (caught on-device 2026-07-23): the clock was frozen
        // but position wander kept adding meters — inflating distance while time stood still, so
        // pace read fast. The processor stays warm exactly like a manual pause.
        let paused = manuallyPaused || state == .autoPaused
        let result = processor.ingest(fix, paused: paused)
        let accepted = result != .rejected
        // Build the route from the Kalman-corrected position (not the raw fix): the first accepted
        // fix (anchor) plus every real move.
        if !manuallyPaused, case .accepted(let added) = result, added > 0 || route.isEmpty {
            route.append(Coordinate(lat: processor.filteredLat, lon: processor.filteredLon))
        }
        // Auto-paused fixes are stored as NOT accepted, exactly like manual ones. They used to be
        // stored accepted — the engine counted zero for them while every "saved route = accepted
        // samples" reader counted the stationary wander at the traffic light, so the saved route
        // grew a scribble and the split/PR reducer inherited both those metres and that time.
        // `pausedSpan` keeps the record honest without destroying it (mark, don't destroy).
        await sink.persistSample(fix, accepted: accepted && !paused, pausedSpan: paused)

        // Moving-time accounting only while actively tracking.
        if state == .tracking, let mark = lastMovingMark {
            movingTimeS += now.timeIntervalSince(mark)
        }
        lastMovingMark = now

        // Auto-pause / resume (manual pause is sticky and not overridden here).
        //
        // An UNKNOWN speed is not evidence of stopping. CoreLocation reports a negative sentinel for
        // `speed` under canopy, in an urban canyon, or on a cold re-acquire — and `max(0,)` turned
        // that sentinel into a confident "stationary", latching auto-pause on an athlete who was
        // still running. That freezes the clock while position-only fixes keep accruing distance,
        // so the run comes back short on time and its pace reads fast. Skip the decision instead:
        // hold whatever state we were in until the device tells us something it actually measured.
        if state != .paused, fix.speedMS >= 0 {
            let pausedBySpeed = processor.shouldAutoPause(speedMS: fix.speedMS, now: now,
                                                          currentlyPaused: state == .autoPaused)
            if !pausedBySpeed {
                // Real movement → a manual-resume override is done its job; normal auto-pause resumes.
                autoPauseSuppressed = false
                if state == .autoPaused { state = .tracking }
                else if state == .gpsLost, accepted { state = .tracking }
            } else if state == .tracking, !autoPauseSuppressed {
                // Stationary and not manually overridden → auto-pause.
                state = .autoPaused
            }
            // else: stationary but the athlete manually resumed → stay tracking (Resume always wins).
        }

        // Re-assert the state invariant after the awaits above: an `await` here is a suspension point,
        // so `finish()` can run (writing the authoritative durationS and moving to .saving/.summary)
        // while this ingest is parked. If it did, bail — otherwise the checkpoint below would clobber
        // that finalized duration with `movingTimeS`.
        guard state == .tracking || state == .autoPaused || state == .gpsLost else { return }

        if let last = lastCheckpoint, now.timeIntervalSince(last) >= Const.checkpointIntervalS {
            await sink.checkpoint(distanceM: processor.distanceM,
                                  durationS: movingTimeS,
                                  elevationGainM: processor.elevationGainM)
            lastCheckpoint = now
        }
    }

    /// Manual Pause. Also honored while `.acquiring` (recording armed but no fix yet — e.g. location
    /// denied, where the state never leaves acquiring) and `.gpsLost`, so the button is never a silent
    /// no-op while the elapsed clock runs.
    func pause() {
        if state == .tracking || state == .autoPaused || state == .acquiring || state == .gpsLost {
            state = .paused
        }
    }
    /// Manual Resume — works from a manual *or* an auto pause, and holds off auto-pause until the athlete
    /// moves again, so the button always responds even when they're standing still.
    func resume() {
        if state == .paused || state == .autoPaused {
            state = .tracking
            lastMovingMark = Date()
            autoPauseSuppressed = true
        }
    }
    func markGPSLost() { if state == .tracking { state = .gpsLost } }

    /// `durationOverrideS` lets the view model supply its continuous elapsed-time clock (which
    /// ticks independently of GPS-fix cadence); falls back to engine-accumulated moving time.
    /// `elapsedOverrideS` is the wall-clock span including pauses; it falls back to the moving
    /// time, which is what a pause-free run's elapsed genuinely is.
    func finish(durationOverrideS: TimeInterval? = nil, elapsedOverrideS: TimeInterval? = nil) async {
        state = .saving
        let duration = durationOverrideS ?? movingTimeS
        await sink.finishWorkout(distanceM: processor.distanceM,
                                 durationS: duration,
                                 elapsedS: max(elapsedOverrideS ?? duration, duration),
                                 elevationGainM: processor.elevationGainM)
        state = .summary
    }

}
