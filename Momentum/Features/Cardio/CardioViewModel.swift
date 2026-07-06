import Foundation
import SwiftData
import CoreLocation
import Observation
import OSLog

/// Bridges `GPSTrackingEngine` to SwiftUI (PRD §4.3, §8.3). Pumps `LocationService.fixes()` into
/// the engine and republishes a snapshot for the live map + hero metric.
@MainActor
@Observable
final class CardioViewModel {
    let type: WorkoutType
    let distanceUnit: DistanceUnit
    /// Optional distance goal (m) — drives the Live Activity goal ring.
    let goalMeters: Double?
    /// When recording actually began (set in `start()`, i.e. right after the countdown).
    private(set) var startedAt = Date()

    private let engine: GPSTrackingEngine
    private let store: GPSWorkoutStore
    private let location: LocationService
    private let liveActivity = CardioActivityController()

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

    // Voice coach (PRD §4.10, Pro). nil when not entitled/disabled, so the loop never depends on it.
    private let voice: (any VoiceCoachServing)?
    private var unitMeters: Double { distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000 }
    private var lastUnitCount = 0
    private var lastBoundaryElapsedS: TimeInterval = 0
    private var lastAnnouncedPaused = false
    private var goalAnnounced = false

    init(type: WorkoutType, container: ModelContainer, distanceUnit: DistanceUnit = .auto,
         goalMeters: Double? = nil, voice: (any VoiceCoachServing)? = nil) {
        self.type = type
        self.distanceUnit = distanceUnit
        self.goalMeters = goalMeters
        self.voice = voice
        self.location = LocationService()
        let store = GPSWorkoutStore(modelContainer: container)
        self.store = store
        self.engine = GPSTrackingEngine(type: type, sink: store)
    }

    /// Open the location stream and watch signal quality without recording yet. Fixes report
    /// accuracy (driving the strength meter + `hasGPSLock`) but are not ingested until `arm()`.
    func beginAcquiring() {
        location.requestAuthorization()
        // Warm start: if iOS already has a fresh, accurate fix (the home map was just showing the
        // user's puck), don't make them watch "Acquiring GPS" — lock immediately and go straight to
        // the countdown, which itself gives the live stream a few seconds to warm up before recording.
        if let fix = location.cachedFix, fix.accuracyM <= Self.lockAccuracyM, fix.ageS < 30 {
            lastAccuracyM = fix.accuracyM
            hasGPSLock = true
        }
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
                self.liveActivity.update(self.liveState())
                self.announceMilestonesIfNeeded()
                self.announcePauseIfChanged()
            }
        }
    }

    /// Speak each completed km/mi with its split pace, and the goal once (voice coach).
    private func announceMilestonesIfNeeded() {
        guard voice != nil else { return }
        let count = Int(distanceM / unitMeters)
        if count > lastUnitCount {
            lastUnitCount = count
            let now = elapsed()
            let splitS = now - lastBoundaryElapsedS
            lastBoundaryElapsedS = now
            voice?.announce(CoachingCueBuilder.milestone(unitCount: count, splitSecPerUnit: splitS, unit: distanceUnit))
        }
        if let goal = goalMeters, goal > 0, !goalAnnounced, distanceM >= goal {
            goalAnnounced = true
            voice?.announce(CoachingCueBuilder.goalReached())
        }
    }

    /// Speak paused/resumed on any transition (manual or GPS auto-pause), deduped.
    private func announcePauseIfChanged() {
        guard voice != nil else { return }
        let p = isPaused
        guard p != lastAnnouncedPaused else { return }
        lastAnnouncedPaused = p
        voice?.announce(p ? CoachingCueBuilder.paused() : CoachingCueBuilder.resumed())
    }

    /// Begin recording for real (called when the countdown hits GO). From here fixes accumulate
    /// into the route + distance; the elapsed clock starts now.
    func arm() async {
        startedAt = Date()
        await engine.begin(now: startedAt)
        workoutId = ActiveWorkoutMarker.pendingID
        snapshot = await engine.snapshot()
        armed = true
        // Light up the lock screen / Dynamic Island for the live run (PRD §23).
        liveActivity.start(title: type.title, symbol: type.systemImage, state: liveState())
    }

    /// Tear down the stream when the user backs out before arming (no workout was ever created).
    func cancelAcquiring() {
        pumpTask?.cancel()
        location.stop()
        liveActivity.end()
    }

    func pause() async { await engine.pause(); snapshot = await engine.snapshot(); syncPauseClock(); liveActivity.update(liveState()); announcePauseIfChanged() }
    func resume() async { await engine.resume(); snapshot = await engine.snapshot(); syncPauseClock(); liveActivity.update(liveState()); announcePauseIfChanged() }

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
        liveActivity.end()
        voice?.stop()
        await engine.finish(durationOverrideS: elapsed())
        // Render the Strava-style route snapshot from the Kalman-filtered coordinates (PRD §8.5) — do
        // this synchronously so the summary always opens with a route image.
        let coords = coordinates
        if coords.count > 1, let data = await RouteSnapshotter.snapshot(coordinates: coords) {
            await store.attachSnapshot(data)
        }
        // Stage 3 (§8.5): snap the finished route to the road/path network in the background, then
        // upgrade the stored route + snapshot. Not awaited — the summary shows the raw trace instantly
        // and the cleaner matched route swaps in via SwiftData observation a moment later. Self-gates
        // on confidence, so trail/off-network runs simply keep the raw trace.
        if MapMatchingService.isEnabled, coords.count > 1 {
            let store = self.store
            let type = self.type
            let log = Logger(subsystem: "com.momentum.app", category: "map-matching")
            Task.detached(priority: .utility) {
                guard let match = await MapMatchingService().match(coordinates: coords,
                                                                   profile: MapMatchingService.profile(for: type)) else {
                    log.notice("map-match: no match (nil) — kept raw trace, input=\(coords.count) pts")
                    return
                }
                guard match.confidence >= MapMatchingService.minConfidence else {
                    log.notice("map-match: rejected confidence=\(match.confidence, format: .fixed(precision: 3)) < gate — kept raw trace")
                    return
                }
                log.notice("map-match: applied confidence=\(match.confidence, format: .fixed(precision: 3)) input=\(coords.count) → matched=\(match.coordinates.count) pts")
                let pairs = match.coordinates.map { [$0.latitude, $0.longitude] }
                guard let routeData = try? JSONEncoder().encode(pairs) else { return }
                await store.attachMatchedRoute(routeData)
                if let snapshot = await RouteSnapshotter.snapshot(coordinates: match.coordinates) {
                    await store.attachSnapshot(snapshot)
                }
            }
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

    // MARK: Live Activity

    /// Pace/speed for the secondary readout — speed for rides, pace otherwise (distance has its own
    /// slot, so we never duplicate it the way `heroValue` would for walks).
    private var paceOrSpeed: (value: String, label: String) {
        switch type.discipline {
        case .cycling:
            let t = elapsed()
            return (Formatters.speed(ms: t > 0 ? distanceM / t : 0, unit: distanceUnit), "Speed")
        default:
            return (Formatters.pace(secPerKm: snapshot?.smoothedPaceSPerKm ?? 0, unit: distanceUnit), "Pace")
        }
    }

    /// Snapshot the current numbers into the Live Activity content state.
    private func liveState() -> CardioActivityAttributes.ContentState {
        let e = elapsed()
        let pace = paceOrSpeed
        return .init(
            timerStart: Date().addingTimeInterval(-e),
            paused: isPaused,
            elapsedText: Formatters.duration(s: e),
            distanceText: secondaryDistance,
            paceText: pace.value,
            paceLabel: pace.label,
            goalFraction: goalMeters.map { $0 > 0 ? max(0, min(1, distanceM / $0)) : 0 })
    }
}
