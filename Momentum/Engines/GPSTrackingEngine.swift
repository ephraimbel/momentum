import Foundation

/// Persistence sink for the GPS engine. Phase 1 backs this with SwiftData (`GPSDetail`/
/// `LocationSample`), persisting each accepted sample immediately and checkpointing aggregates
/// every 5s (PRD §8.3 durability). A no-op default keeps the engine testable in isolation.
protocol GPSWorkoutSink: Sendable {
    /// Create the durable `Workout` + `GPSDetail` and mark it the active (recoverable) workout.
    func beginWorkout(type: WorkoutType, startedAt: Date) async
    /// Persist a single fix immediately (the durability guarantee).
    func persistSample(_ fix: GPSProcessor.Fix, accepted: Bool) async
    /// Update rolled-up aggregates (every ~5s).
    func checkpoint(distanceM: Double, durationS: TimeInterval, elevationGainM: Double) async
    /// Finalize aggregates and clear the active-workout marker.
    func finishWorkout(distanceM: Double, durationS: TimeInterval, elevationGainM: Double,
                       smoothedPaceSPerKm: Double) async
}

struct NoopGPSWorkoutSink: GPSWorkoutSink {
    func beginWorkout(type: WorkoutType, startedAt: Date) async {}
    func persistSample(_ fix: GPSProcessor.Fix, accepted: Bool) async {}
    func checkpoint(distanceM: Double, durationS: TimeInterval, elevationGainM: Double) async {}
    func finishWorkout(distanceM: Double, durationS: TimeInterval, elevationGainM: Double,
                       smoothedPaceSPerKm: Double) async {}
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
        static let heroUpdateThrottleS = 1.0
        static let routeRedrawThrottleS = 0.5
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
        let result = processor.ingest(fix, paused: manuallyPaused)
        let accepted = result != .rejected
        // Build the route from the Kalman-corrected position (not the raw fix): the first accepted
        // fix (anchor) plus every real move.
        if !manuallyPaused, case .accepted(let added) = result, added > 0 || route.isEmpty {
            route.append(Coordinate(lat: processor.filteredLat, lon: processor.filteredLon))
        }
        await sink.persistSample(fix, accepted: accepted && !manuallyPaused)

        // Moving-time accounting only while actively tracking.
        if state == .tracking, let mark = lastMovingMark {
            movingTimeS += now.timeIntervalSince(mark)
        }
        lastMovingMark = now

        // Auto-pause / resume (manual pause is sticky and not overridden here).
        if state != .paused {
            let pausedBySpeed = processor.shouldAutoPause(speedMS: max(0, fix.speedMS), now: now,
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
    func finish(durationOverrideS: TimeInterval? = nil) async {
        state = .saving
        await sink.finishWorkout(distanceM: processor.distanceM,
                                 durationS: durationOverrideS ?? movingTimeS,
                                 elevationGainM: processor.elevationGainM,
                                 smoothedPaceSPerKm: processor.smoothedPaceSPerKm)
        state = .summary
    }

}
