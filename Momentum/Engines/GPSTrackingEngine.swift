import Foundation

/// Persistence sink for the GPS engine. Phase 1 backs this with SwiftData (`GPSDetail`/
/// `LocationSample`), persisting each accepted sample immediately and checkpointing aggregates
/// every 5s (PRD §8.3 durability). A no-op default keeps the engine testable in isolation.
protocol GPSWorkoutSink: Sendable {
    func persistSample(_ fix: GPSProcessor.Fix, accepted: Bool) async
    func checkpoint(distanceM: Double, durationS: TimeInterval, elevationGainM: Double) async
}

struct NoopGPSWorkoutSink: GPSWorkoutSink {
    func persistSample(_ fix: GPSProcessor.Fix, accepted: Bool) async {}
    func checkpoint(distanceM: Double, durationS: TimeInterval, elevationGainM: Double) async {}
}

/// Cardio capture engine (PRD §8.3). A strict state machine over a pure `GPSProcessor`.
/// Durable by contract: every accepted sample is persisted via the sink as it arrives.
actor GPSTrackingEngine {

    enum State: String, Equatable, Sendable {
        case idle, acquiring, tracking, autoPaused, paused, gpsLost, saving, summary, recovered
    }

    enum Const {
        static let heroUpdateThrottleS = 1.0
        static let routeRedrawThrottleS = 0.5
        static let checkpointIntervalS = 5.0
        static let liveActivityUpdateS = 3.0
        static let gpsLostTimeoutS = 8.0   // no accepted fix for this long → GPSLost (keep timing)
    }

    let type: WorkoutType
    private(set) var state: State = .idle
    private var processor: GPSProcessor
    private let sink: GPSWorkoutSink

    private var startedAt: Date?
    private var lastCheckpoint: Date?
    /// Accumulated *moving* time (excludes paused spans).
    private(set) var movingTimeS: TimeInterval = 0
    private var lastMovingMark: Date?

    init(type: WorkoutType, sink: GPSWorkoutSink = NoopGPSWorkoutSink()) {
        self.type = type
        self.processor = GPSProcessor(config: .forType(type))
        self.sink = sink
    }

    // Read-only snapshots for the view model.
    var distanceM: Double { processor.distanceM }
    var smoothedPaceSPerKm: Double { processor.smoothedPaceSPerKm }
    var elevationGainM: Double { processor.elevationGainM }

    func begin(now: Date = Date()) {
        guard state == .idle || state == .recovered else { return }
        state = .acquiring
        startedAt = now
        lastMovingMark = now
        lastCheckpoint = now
    }

    /// Ingest a raw location fix. Drives accept/reject, distance, auto-pause, and persistence.
    func ingest(_ fix: GPSProcessor.Fix, now: Date = Date()) async {
        guard state != .idle, state != .saving, state != .summary else { return }

        if state == .acquiring { state = .tracking }

        let result = processor.ingest(fix)
        let accepted = result != .rejected
        await sink.persistSample(fix, accepted: accepted)

        // Moving-time accounting only while actively tracking.
        if state == .tracking, let mark = lastMovingMark {
            movingTimeS += now.timeIntervalSince(mark)
        }
        lastMovingMark = now

        // Auto-pause / resume (manual pause is sticky and not overridden here).
        if state != .paused {
            let pausedBySpeed = processor.shouldAutoPause(speedMS: max(0, fix.speedMS), now: now)
            if pausedBySpeed, state == .tracking {
                state = .autoPaused
            } else if !pausedBySpeed, state == .autoPaused {
                state = .tracking
            } else if state == .gpsLost, accepted {
                state = .tracking
            }
        }

        if let last = lastCheckpoint, now.timeIntervalSince(last) >= Const.checkpointIntervalS {
            await sink.checkpoint(distanceM: processor.distanceM,
                                  durationS: movingTimeS,
                                  elevationGainM: processor.elevationGainM)
            lastCheckpoint = now
        }
    }

    func pause() { if state == .tracking || state == .autoPaused { state = .paused } }
    func resume() { if state == .paused { state = .tracking; lastMovingMark = Date() } }
    func markGPSLost() { if state == .tracking { state = .gpsLost } }

    func finish() async {
        state = .saving
        await sink.checkpoint(distanceM: processor.distanceM,
                              durationS: movingTimeS,
                              elevationGainM: processor.elevationGainM)
        state = .summary
    }

    /// Re-enter after a cold launch with an unfinished workout (the "Resume?" path).
    func markRecovered() { state = .recovered }
}
