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
    /// Optional structured session (warm-up → reps → cool-down) to guide in real time (R1). nil → a
    /// plain free/easy run with just the hero metrics.
    let structured: StructuredWorkout?
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
    // Manual-only pause clock for structured guidance: a timed recovery must keep counting down through
    // GPS *auto*-pause (you slow to a walk or stop during the recovery), freezing only when *you* tap Pause.
    private var manualPausedTotalS: TimeInterval = 0
    private var manualPauseStartedAt: Date?

    // Voice coach (PRD §4.10, Pro). nil when not entitled/disabled, so the loop never depends on it.
    private let voice: (any VoiceCoachServing)?

    // Cadence source (CoreMotion, R3). Live steps/min on the run screen + an averaged value stored at
    // finish. Hardware-only — nil in the simulator, so the run never depends on it.
    private let motion: any MotionServing
    private var cadenceReadings: [Int] = []

    // Heart-rate source (BLE monitor, R3). Live BPM + zone on the run screen and an averaged value
    // stored at finish. Needs a paired strap; nil-safe so the run never depends on it.
    private let heartRate: any HeartRateServing
    /// The athlete's max HR (Tanaka estimate or measured) — used to band live BPM into a zone.
    let maxHR: Int?
    private var hrReadings: [Int] = []

    private var unitMeters: Double { distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000 }
    private var lastUnitCount = 0
    private var lastBoundaryElapsedS: TimeInterval = 0
    private var lastAnnouncedPaused = false
    private var goalAnnounced = false

    // Structured-workout guidance (R1). The tracker is pure; a 1 Hz task advances it and voices the
    // transitions. nil for a plain run.
    private(set) var tracker: StructuredRunTracker?
    private var structuredTask: Task<Void, Never>?
    private var structuredCompleteAnnounced = false
    private var lastPaceNudgeAt: TimeInterval = 0
    private var recoveryReadyBuzzed = false

    init(type: WorkoutType, container: ModelContainer, distanceUnit: DistanceUnit = .auto,
         goalMeters: Double? = nil, structured: StructuredWorkout? = nil,
         voice: (any VoiceCoachServing)? = nil, motion: (any MotionServing)? = nil,
         heartRate: (any HeartRateServing)? = nil, maxHR: Int? = nil) {
        self.type = type
        self.distanceUnit = distanceUnit
        self.goalMeters = goalMeters
        self.structured = structured
        self.voice = voice
        self.motion = motion ?? MotionService()
        self.heartRate = heartRate ?? HeartRateMonitor()
        self.maxHR = maxHR
        self.location = LocationService()
        let store = GPSWorkoutStore(modelContainer: container)
        self.store = store
        self.engine = GPSTrackingEngine(type: type, sink: store)
        self.tracker = structured.map { StructuredRunTracker(steps: $0.steps) }
    }

    /// Open the location stream and watch signal quality without recording yet. Fixes report
    /// accuracy (driving the strength meter + `hasGPSLock`) but are not ingested until `arm()`.
    func beginAcquiring() {
        location.requestAuthorization()
        motion.requestAuthorization()   // prime the CoreMotion prompt now, alongside location
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
                self.sampleCadence()
                self.liveActivity.update(self.liveState())
                self.announceMilestonesIfNeeded()
                self.announcePauseIfChanged()
            }
        }
    }

    /// Speak each completed km/mi with its split pace, and the goal once (voice coach). Suppressed for
    /// structured sessions — those get their own per-step rep/recovery cues instead of mile splits.
    private func announceMilestonesIfNeeded() {
        guard voice != nil, structured == nil else { return }
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
        motion.start()      // begin cadence updates now that recording is live
        heartRate.start()   // scan for a BLE HR strap (no-op without one)
        workoutId = ActiveWorkoutMarker.pendingID
        snapshot = await engine.snapshot()
        armed = true
        // Light up the lock screen / Dynamic Island for the live run (PRD §23).
        liveActivity.start(title: type.title, symbol: type.systemImage, state: liveState())
        // Kick off guided-workout tracking: announce the first step and advance it once a second,
        // independent of GPS-fix cadence so timed recoveries count down while you stand still.
        if let step = tracker?.current {
            Haptics.medium()   // the "go" cue at step one, matching every later transition
            voice?.announce(CoachingCueBuilder.stepStart(step))
            structuredTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    self.tickStructured()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    // MARK: Structured-workout tracking (R1)

    /// Advance the guided step against the latest distance/elapsed and voice any transition. Called
    /// once a second while recording.
    private func tickStructured() {
        guard var t = tracker, !t.isComplete else { return }
        // Timed steps advance on the manual-only clock so a recovery counts down through GPS auto-pause;
        // distance steps ignore the clock entirely (they key off `d`).
        let d = distanceM, e = structuredElapsed()
        if t.advance(distanceM: d, elapsedS: e) {
            tracker = t
            recoveryReadyBuzzed = false              // fresh step — re-arm the recovery countdown buzz
            if t.isComplete { announceStructuredComplete() }
            else if let step = t.current {
                Haptics.medium()
                voice?.announce(CoachingCueBuilder.stepStart(step))
            }
            return
        }
        tracker = t
        // Don't coach a paused athlete: pace reads are stale and time isn't advancing.
        guard !isPaused else { return }
        // A single "get ready" buzz as a timed recovery is about to end, so the next rep doesn't
        // start by surprise.
        if let step = t.current, step.kind == .recovery, step.target.isTime, !recoveryReadyBuzzed,
           t.remaining(distanceM: d, elapsedS: e) <= 3 {
            recoveryReadyBuzzed = true
            Haptics.medium()
        }
        maybeNudgePace(at: e)
    }

    /// End the current step now (the athlete's Lap / Skip control).
    func skipStep() {
        guard var t = tracker, !t.isComplete else { return }
        t.skip(distanceM: distanceM, elapsedS: structuredElapsed())
        tracker = t
        Haptics.medium()
        if t.isComplete { announceStructuredComplete() }
        else if let step = t.current { voice?.announce(CoachingCueBuilder.stepStart(step)) }
    }

    private func announceStructuredComplete() {
        guard !structuredCompleteAnnounced else { return }
        structuredCompleteAnnounced = true
        Haptics.celebration()
        voice?.announce(CoachingCueBuilder.workoutComplete())
    }

    /// A throttled pace nudge inside a work step when you drift outside the target band. Held off for
    /// the first ~10 s of a step so the smoothed pace (EMA) has caught up from the previous step's
    /// effort — otherwise a rep would open with a spurious "pick it up".
    private func maybeNudgePace(at now: TimeInterval) {
        guard voice != nil, now - lastPaceNudgeAt > 25,
              let t = tracker, now - t.anchorElapsedS > 10 else { return }
        let a = stepAdherence
        guard a == .tooFast || a == .tooSlow else { return }
        lastPaceNudgeAt = now
        voice?.announce(CoachingCueBuilder.paceNudge(a))
    }

    /// Tear down the stream when the user backs out before arming (no workout was ever created).
    func cancelAcquiring() {
        pumpTask?.cancel()
        structuredTask?.cancel()
        location.stop()
        motion.stop()
        heartRate.stop()
        liveActivity.end()
    }

    /// Record the current cadence + heart-rate readings for the run's averages — skipped while paused.
    private func sampleCadence() {
        guard !isPaused else { return }
        if let c = motion.cadenceStepsPerMin, c > 0 { cadenceReadings.append(c) }
        if let b = heartRate.bpm, b > 0 { hrReadings.append(b) }
    }

    /// Live cadence (steps/min) for the run screen; nil until CoreMotion reports (never in the sim).
    var cadence: Int? { motion.cadenceStepsPerMin }

    /// Live heart rate (bpm) from the paired BLE monitor; nil without a strap.
    var bpm: Int? { heartRate.bpm }

    /// Current HR zone label ("Z1"…"Z5") when both a live BPM and a max HR are known.
    var hrZone: String? {
        guard let b = heartRate.bpm, b > 0, let m = maxHR, m > 0 else { return nil }
        return "Z\(HeartRateZones.zone(forBpm: b, maxHR: m))"
    }

    func pause() async { await engine.pause(); snapshot = await engine.snapshot(); syncPauseClock(); liveActivity.update(liveState()); announcePauseIfChanged() }
    func resume() async { await engine.resume(); snapshot = await engine.snapshot(); syncPauseClock(); liveActivity.update(liveState()); announcePauseIfChanged() }

    /// Elapsed (moving) time since start, frozen while paused — ticks every second regardless of
    /// GPS fixes. This is the timer shown on the live screen and saved as the workout duration.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        let end = pauseStartedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedTotalS)
    }

    /// Elapsed time for structured timed steps — freezes only on MANUAL pause. A timed recovery keeps
    /// counting through GPS auto-pause (when you slow to a walk or stop during the recovery), so a guided
    /// interval never stalls waiting for movement.
    func structuredElapsed(at now: Date = Date()) -> TimeInterval {
        let end = manualPauseStartedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - manualPausedTotalS)
    }

    /// Open/close a paused span when the recording state changes. Tracks two spans: the moving-time
    /// clock (any pause, manual or auto) and a manual-only clock for structured guidance.
    private func syncPauseClock() {
        if isPaused {
            if pauseStartedAt == nil { pauseStartedAt = Date() }
        } else if let started = pauseStartedAt {
            pausedTotalS += Date().timeIntervalSince(started)
            pauseStartedAt = nil
        }
        // Manual-only span (state == .paused, i.e. the user tapped Pause) for the structured-step clock.
        if state == .paused {
            if manualPauseStartedAt == nil { manualPauseStartedAt = Date() }
        } else if let started = manualPauseStartedAt {
            manualPausedTotalS += Date().timeIntervalSince(started)
            manualPauseStartedAt = nil
        }
    }

    func finish() async -> UUID? {
        pumpTask?.cancel()
        structuredTask?.cancel()
        location.stop()
        motion.stop()
        heartRate.stop()
        liveActivity.end()
        voice?.stop()
        await engine.finish(durationOverrideS: elapsed())
        // Persist the run's average cadence + heart rate when the sensors produced readings.
        if let avgCadence = RunSignals.mean(cadenceReadings) { await store.attachCadence(avgCadence) }
        if let avgHR = RunSignals.mean(hrReadings) { await store.attachHR(avgHR) }
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

    // MARK: Structured-workout display

    var currentStep: WorkoutStep? { tracker?.current }
    var structuredComplete: Bool { tracker?.isComplete ?? false }

    /// Banner title: "Rep 3 / 6" for reps, else the kind ("Warm up", "Recovery", "Cool down").
    var stepTitle: String { currentStep.map(Self.stepLabel) ?? "" }

    /// The current step's remaining amount as a big value + caption ("240" / "M LEFT", "1:30" / "LEFT").
    var stepRemaining: (value: String, caption: String) {
        guard let t = tracker, let step = t.current else { return ("", "") }
        let rem = t.remaining(distanceM: distanceM, elapsedS: structuredElapsed())
        switch step.target {
        case let .distance(d):
            return d < 1000
                ? ("\(Int(rem.rounded()))", "M LEFT")
                : (Formatters.distance(meters: rem, unit: distanceUnit).components(separatedBy: " ").first ?? "0",
                   "\(unitLabelUpper) LEFT")
        case .duration:
            return (Formatters.duration(s: rem), "LEFT")
        }
    }

    /// 0…1 of the current step completed — drives the step progress ring.
    var stepProgress: Double {
        tracker?.progress(distanceM: distanceM, elapsedS: structuredElapsed()) ?? 0
    }

    /// Pace-adherence verdict for the current work step (drives the on-pace iridescent glow).
    var stepAdherence: StructuredRunTracker.Adherence {
        tracker?.adherence(currentPaceSPerKm: snapshot?.smoothedPaceSPerKm ?? 0) ?? .noTarget
    }

    /// The current step's target pace, when it has one.
    var stepTargetPaceText: String? {
        guard let p = currentStep?.paceSPerKm, p > 0 else { return nil }
        return Formatters.pace(secPerKm: p, unit: distanceUnit)
    }

    /// "Next · Recovery" preview, or nil on the last step.
    var stepNextText: String? { tracker?.next.map { "Next · \(Self.stepLabel($0))" } }

    /// Rep progress across the session's work steps, for the dot row. nil for non-rep sessions.
    var repProgress: (done: Int, total: Int)? {
        guard let total = structured?.steps.first(where: { $0.repTotal != nil })?.repTotal,
              let idx = tracker?.index else { return nil }
        let done = (structured?.steps.prefix(idx).filter { $0.kind == .work }.count) ?? 0
        return (min(done, total), total)
    }

    private var unitLabelUpper: String { distanceUnit.resolved() == .imperial ? "MI" : "KM" }

    private static func stepLabel(_ step: WorkoutStep) -> String {
        if let i = step.repIndex, let n = step.repTotal { return "\(step.displayNoun) \(i) / \(n)" }
        return step.displayNoun
    }

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
