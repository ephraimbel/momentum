import Foundation
import SwiftData
import CoreLocation
import Observation

/// Bridges `GPSTrackingEngine` to SwiftUI (PRD §4.3, §8.3). Pumps `LocationService.fixes()` into
/// the engine and republishes a snapshot for the live map + hero metric.
@MainActor
@Observable
final class CardioViewModel {
    let type: WorkoutType
    let distanceUnit: DistanceUnit
    /// When recording actually began (set in `start()`, i.e. right after the countdown).
    private(set) var startedAt = Date()

    private let engine: GPSTrackingEngine
    private let store: GPSWorkoutStore
    private let location: LocationService

    private(set) var snapshot: GPSTrackingEngine.LiveSnapshot?
    private(set) var lastAccuracyM: Double?
    private(set) var workoutId: UUID?
    private var pumpTask: Task<Void, Never>?

    /// True once a fix lands within the lock accuracy band — the cue to leave the "acquiring" gate
    /// and start the countdown (PRD §4.3; mirrors Strava's "GPS Signal Acquired").
    private(set) var hasGPSLock = false
    /// Until armed (after the countdown), incoming fixes only report signal quality — they do not
    /// accumulate distance or extend the route, so a weak pre-start fix can't poison the trace.
    private var armed = false
    /// Research band for running/pace apps is ~30–50m; we lock at the tight end.
    private static let lockAccuracyM = 30.0

    // Elapsed-time clock — ticks continuously from start, freezing while paused (manual or auto).
    // Independent of GPS-fix cadence so the timer always advances every second.
    private var pausedTotalS: TimeInterval = 0
    private var pauseStartedAt: Date?

    init(type: WorkoutType, container: ModelContainer, distanceUnit: DistanceUnit = .auto) {
        self.type = type
        self.distanceUnit = distanceUnit
        self.location = LocationService()
        let store = GPSWorkoutStore(modelContainer: container)
        self.store = store
        self.engine = GPSTrackingEngine(type: type, sink: store)
    }

    /// Open the location stream and watch signal quality without recording yet. Fixes report
    /// accuracy (driving the strength meter + `hasGPSLock`) but are not ingested until `arm()`.
    func beginAcquiring() {
        location.requestAuthorization()
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await fix in self.location.fixes() {
                self.lastAccuracyM = fix.accuracyM
                guard self.armed else {
                    if fix.accuracyM > 0, fix.accuracyM <= Self.lockAccuracyM { self.hasGPSLock = true }
                    continue
                }
                await self.engine.ingest(fix)
                self.snapshot = await self.engine.snapshot()
                self.syncPauseClock()
            }
        }
    }

    /// Begin recording for real (called when the countdown hits GO). From here fixes accumulate
    /// into the route + distance; the elapsed clock starts now.
    func arm() async {
        startedAt = Date()
        await engine.begin(now: startedAt)
        workoutId = ActiveWorkoutMarker.pendingID
        snapshot = await engine.snapshot()
        armed = true
    }

    /// Tear down the stream when the user backs out before arming (no workout was ever created).
    func cancelAcquiring() {
        pumpTask?.cancel()
        location.stop()
    }

    func pause() async { await engine.pause(); snapshot = await engine.snapshot(); syncPauseClock() }
    func resume() async { await engine.resume(); snapshot = await engine.snapshot(); syncPauseClock() }

    /// Elapsed (moving) time since start, frozen while paused — ticks every second regardless of
    /// GPS fixes. This is the timer shown on the live screen and saved as the workout duration.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        let end = pauseStartedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedTotalS)
    }

    /// Open/close a paused span when the recording state changes (manual pause or GPS auto-pause).
    private func syncPauseClock() {
        if isPaused {
            if pauseStartedAt == nil { pauseStartedAt = Date() }
        } else if let started = pauseStartedAt {
            pausedTotalS += Date().timeIntervalSince(started)
            pauseStartedAt = nil
        }
    }

    func finish() async -> UUID? {
        pumpTask?.cancel()
        location.stop()
        await engine.finish(durationOverrideS: elapsed())
        // Render the Strava-style route snapshot from accepted coordinates (PRD §8.5).
        let coords = coordinates
        if coords.count > 1, let data = await RouteSnapshotter.snapshot(coordinates: coords) {
            await store.attachSnapshot(data)
        }
        return workoutId
    }

    // MARK: Derived display

    var state: GPSTrackingEngine.State { snapshot?.state ?? .idle }

    var coordinates: [CLLocationCoordinate2D] {
        (snapshot?.route ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    var distanceM: Double { snapshot?.distanceM ?? 0 }
    var movingTimeS: TimeInterval { snapshot?.movingTimeS ?? 0 }

    /// The discipline's hero metric (PRD §4.3): run → pace, ride → speed, walk → distance.
    var heroValue: String {
        switch type.discipline {
        case .cycling:
            let t = elapsed()
            let speed = t > 0 ? distanceM / t : 0
            return Formatters.speed(ms: speed, unit: distanceUnit)
        case .walking:
            return Formatters.distance(meters: distanceM, unit: distanceUnit)
        default:
            return Formatters.pace(secPerKm: snapshot?.smoothedPaceSPerKm ?? 0, unit: distanceUnit)
        }
    }

    var heroLabel: String {
        switch type.discipline {
        case .cycling: "Speed"
        case .walking: "Distance"
        default: "Pace"
        }
    }

    var secondaryDistance: String { Formatters.distance(meters: distanceM, unit: distanceUnit) }

    var isPaused: Bool { state == .paused || state == .autoPaused }

    /// True once the user has declined location — the route can't be tracked until they re-enable
    /// it in Settings. Drives the in-recording banner.
    var locationDenied: Bool { location.isDenied }

    /// 0 (weak) … 1 (strong) GPS strength from the latest fix accuracy.
    var gpsStrength: Double {
        guard let acc = lastAccuracyM, acc > 0 else { return 0 }
        return max(0, min(1, (40 - acc) / 30))
    }
}
