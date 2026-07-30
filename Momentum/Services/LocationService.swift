import Foundation
import CoreLocation
import Observation

/// Live GPS source (PRD §8.3). Uses the iOS 17+ `CLLocationUpdate.liveUpdates` async sequence —
/// no delegate for fixes — and a `CLLocationManager` for authorization, observed via its delegate
/// so the UI can react when the user grants or denies access. Emits `GPSProcessor.Fix` values; the
/// cardio view model pumps these into `GPSTrackingEngine`.
@MainActor
@Observable
final class LocationService: NSObject, LocationServing, CLLocationManagerDelegate {
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// Keeps `liveUpdates` delivering while the app is backgrounded (locked phone in a pocket — the
    /// normal case for a run). Without this session iOS suspends location delivery on background,
    /// and the first fixes on return are dropped as stale — freezing distance while the timer runs.
    /// Held for the lifetime of the recording stream; invalidated in `stop()`.
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?

    /// Current authorization, kept live by the delegate so views update when the user responds.
    private(set) var authorizationStatus: CLAuthorizationStatus

    /// Last known coordinate from a one-shot fix — lets the home map center on the athlete at rest
    /// (the live recording stream is separate, via `fixes()`).
    private(set) var lastLocation: CLLocationCoordinate2D?

    override init() {
        authorizationStatus = .notDetermined
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    /// The user actively declined (or is restricted) — recording can't track a route until they
    /// re-enable access in Settings.
    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func requestAuthorization() {
#if DEBUG
        // UI tests drive a synthetic route (see `fixes()`); skip the real prompt so no system alert
        // interrupts the flow, report authorized so the acquiring gate behaves normally, and seed a
        // last-known location so the home map centers (as it would with a real fix).
        if Self.isUITestRoute || Self.isRun4 {
            authorizationStatus = .authorizedWhenInUse
            // Center the home map where the run will actually begin, so it doesn't jump when tracking starts.
            lastLocation = Self.isRun4
                ? CLLocationCoordinate2D(latitude: 37.7735, longitude: -122.4825)      // run4 snake-route start
                : CLLocationCoordinate2D(latitude: 37.7917, longitude: -122.3996)      // --ui-test-route track
            return
        }
#endif
        manager.requestWhenInUseAuthorization()
        if isAuthorized { manager.requestLocation() }   // one-shot fix to center the home map
    }

    /// Ask for a single fresh fix (used to recenter the home map on demand).
    func refreshLocation() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }

    /// The most-recent known coordinate, however stale — for framing non-critical UI like the map
    /// style previews around the athlete's area. Never used for tracking (no accuracy gate).
    var lastCoordinate: CLLocationCoordinate2D? { manager.location?.coordinate }

    /// The system's most-recent cached fix — its accuracy and age — if iOS already knows where we are.
    /// Lets a run **warm-start**: skip the "Acquiring GPS" gate when the location is already good (the
    /// home map was just showing the puck). nil if there's no usable cached fix yet.
    var cachedFix: (accuracyM: Double, ageS: TimeInterval)? {
        guard let loc = manager.location, loc.horizontalAccuracy > 0 else { return nil }
        return (loc.horizontalAccuracy, Date().timeIntervalSince(loc.timestamp))
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if self.isAuthorized { manager.requestLocation() }   // grant just landed → grab a fix
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.last?.coordinate else { return }
        Task { @MainActor in self.lastLocation = coord }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // One-shot fix failed (no signal / sim with no location) — keep last known; UI falls back.
    }

    /// Stream accepted-or-not raw fixes. The engine's `GPSProcessor` applies the accept gate.
    func fixes() -> AsyncStream<GPSProcessor.Fix> {
#if DEBUG
        if Self.isUITestRoute || Self.isRun4 { return simulatedRouteFixes() }
#endif
        // Must exist before updates begin, and must outlive the stream — otherwise iOS stops
        // delivering fixes the moment the screen locks.
        backgroundSession = CLBackgroundActivitySession()
        return AsyncStream { continuation in
            let task = Task {
                // Re-subscribe on stream end: a transient CoreLocation error (or a system hiccup on
                // background/foreground transitions) ends `liveUpdates` — without this loop that
                // silently killed GPS for the rest of the run (trace + distance frozen forever,
                // timer still counting). Only cancellation (stop()/finish) truly ends the stream;
                // genuine denial just keeps erroring into the backoff while the UI shows the
                // denied banner via `authorizationStatus`.
                while !Task.isCancelled {
                    do {
                        for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                            if Task.isCancelled { break }
                            guard let loc = update.location else { continue }
                            continuation.yield(GPSProcessor.Fix(
                                t: loc.timestamp,
                                lat: loc.coordinate.latitude,
                                lon: loc.coordinate.longitude,
                                accuracyM: loc.horizontalAccuracy,
                                speedMS: loc.speed,
                                altitudeM: loc.altitude
                            ))
                        }
                    } catch {
                        // fall through to the backoff and re-subscribe
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            self.streamTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    // Launch-arg test/marketing hooks — defined in ALL configs (NOT behind #if DEBUG) so the call
    // sites in the app + services compile in Release. They are pure ProcessInfo checks, always false
    // in production (users never pass these args); the simulated-route machinery they gate stays
    // DEBUG-only below. Guarding here, at the source, keeps every call site safe without scattering
    // #if DEBUG across in-flight view/view-model files.
    /// Launched for the live-run UI test, which can't rely on a real CoreLocation feed in the sim.
    static var isUITestRoute: Bool { debugFlag("--ui-test-route") }
    /// Marketing shot: fast-forward the simulated run to a ~2 mi mid-run state (route drawn, distance
    /// well past 0.0) instead of the ~48 m a real-time feed reaches in a screenshot window.
    static var isMidway: Bool { debugFlag("--live-run-midway") }
    /// Core-flow E2E test (`--ui-test-run4`): a full **4-mile run at 6:00/mi**, traced fast (burst)
    /// then held real-time so an XCUITest has time to Pause/Resume/Finish.
    static var isRun4: Bool { debugFlag("--ui-test-run4") }

#if DEBUG

    /// A deterministic ~3 m/s track: tight-accuracy fixes every 0.5 s so the run engine locks GPS,
    /// leaves `.acquiring` for `.tracking`, and stays above the auto-pause speed gate — exactly the
    /// conditions the Pause/Resume control needs, with none of the sim's GPS flakiness. Heads north
    /// with a gentle S-curve so route renders (live trace, Live Activity thumb) show real shape.
    ///
    /// `--live-run-midway` bursts the first ~2 mi into the trace fast: the fix *timestamps* still
    /// advance a realistic 0.5 s/tick (so the Doppler accept-gate and smoothed pace stay honest — a
    /// future-dated fix passes the age gate), only the wall-clock sleep shrinks. After the burst it
    /// settles to real time for the live tip. The view model backdates its elapsed clock to match, so
    /// the frame reads as a coherent "2 mi in ~18 min at ~8:56/mi".
    private func simulatedRouteFixes() -> AsyncStream<GPSProcessor.Fix> {
        // The marketing shot (`--live-run-midway`) traces a REAL San Francisco street loop so the run
        // looks like something an athlete actually ran — never a straight line out over the bay. Each
        // fix carries a virtual timestamp advancing at ~3 m/s along the real geometry (so pace + the
        // Doppler gate stay honest; future-dated fixes pass the age gate), and the wall-clock sleep is
        // tiny until ~2 mi is drawn, then real-time for the live tip.
        // `--ui-test-run4`: 4 miles @ 6:00/mi (4.47 m/s). Densify the ~2 mi loop to ~6 m spacing (a
        // realistic 1.3 s between fixes at this pace — a proper test that the trace stays smooth and
        // never breaks up at speed), loop it until 4 mi is covered, burst it fast, then hold real-time.
        if Self.isRun4, let base0 = Self.snakeRoute(), base0.count > 1 {
            let route = Self.densify(base0, everyMeters: 6)
            return AsyncStream { continuation in
                let task = Task {
                    let base = Date()
                    var vt = 0.0, i = 0, meters = 0.0
                    let target = 4.0 * Formatters.metersPerMile   // 4 miles
                    while !Task.isCancelled {
                        let p = route[i % route.count]
                        continuation.yield(GPSProcessor.Fix(
                            t: base.addingTimeInterval(vt), lat: p.0, lon: p.1,
                            accuracyM: 5, speedMS: 4.47, altitudeM: 0))
                        let next = route[(i + 1) % route.count]
                        let d = Geo.distance(lat1: p.0, lon1: p.1, lat2: next.0, lon2: next.1)
                        vt += max(0.3, d / 4.47)          // 6:00/mi virtual pace keeps the Doppler gate honest
                        meters += d
                        let bursting = meters < target     // draw the whole 4 mi fast, then crawl real-time
                        i += 1
                        // ~55 ms/fix keeps the trace-render rate ≈10 Hz — Mapbox draws each update
                        // cleanly (a 9 ms firehose flickered the growing tip into transient gaps),
                        // and the dot's follow-camera keeps up so the puck stays glued to the tip.
                        try? await Task.sleep(for: .milliseconds(bursting ? 55 : 500))
                    }
                    continuation.finish()
                }
                self.streamTask = task
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        if Self.isMidway, let route = Self.landRoute(), route.count > 1 {
            return AsyncStream { continuation in
                let task = Task {
                    let base = Date()
                    var vt = 0.0, i = 0
                    while !Task.isCancelled {
                        let p = route[i % route.count]
                        continuation.yield(GPSProcessor.Fix(
                            t: base.addingTimeInterval(vt), lat: p.0, lon: p.1,
                            accuracyM: 5, speedMS: 3.6, altitudeM: 0))
                        let next = route[(i + 1) % route.count]
                        vt += max(0.4, Geo.distance(lat1: p.0, lon1: p.1, lat2: next.0, lon2: next.1) / 3.0)
                        // Burst exactly ONE full lap fast so the whole loop draws clean and closed, then
                        // crawl real-time (a 2nd lap overlaps the first — trace stays a single loop) so
                        // the puck keeps moving and GPS stays "Strong" for the shot.
                        let bursting = i < route.count
                        i += 1
                        try? await Task.sleep(for: .milliseconds(bursting ? 7 : 500))
                    }
                    continuation.finish()
                }
                self.streamTask = task
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        // Non-midway (`--ui-test-route` for the Pause/Resume UI test): a deterministic fine ~3 m/s
        // track — tight-accuracy fixes every 0.5 s so the engine locks GPS and leaves `.acquiring`.
        return AsyncStream { continuation in
            let task = Task {
                var lat = 37.7917
                let lon = -122.3996
                var tick = 0.0
                while !Task.isCancelled {
                    let wobble = 0.00045 * sin(tick * .pi / 90)
                    continuation.yield(GPSProcessor.Fix(
                        t: Date(), lat: lat, lon: lon + wobble,
                        accuracyM: 5, speedMS: 3, altitudeM: 0))
                    lat += 0.0000128   // ~1.4 m north per tick
                    tick += 0.5
                    try? await Task.sleep(for: .milliseconds(500))
                }
                continuation.finish()
            }
            self.streamTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A clean, non-self-overlapping ~6 mi path through the Inner Richmond grid for the core-flow E2E
    /// test (`--ui-test-run4`): E-W legs along successive streets joined by short N-S hops
    /// (boustrophedon), so the 4 mi we draw is a single sweep that never laps over itself. A *looped*
    /// route's self-overlap made it impossible to see whether the puck sits at the trace tip (and the
    /// overlapping lines z-fought into false "breakages") — a single pass keeps both unambiguous.
    private static func snakeRoute() -> [(Double, Double)]? {
        let lonW = -122.4825, lonE = -122.4665     // ~24th Ave ↔ ~14th Ave, ~1.4 km E-W legs
        let lats = [37.7735, 37.7757, 37.7779, 37.7801, 37.7823, 37.7845]   // successive E-W streets, S→N
        var pts: [(Double, Double)] = []
        for (r, lat) in lats.enumerated() {
            let ends = r % 2 == 0 ? (lonW, lonE) : (lonE, lonW)
            pts.append((lat, ends.0)); pts.append((lat, ends.1))
        }
        return pts
    }

    /// A clean, real ~2 mi closed loop that FOLLOWS STREETS — a Richmond-district grid loop, snapped
    /// to real roads via the Mapbox Directions API, de-spurred and downsampled (see
    /// `scripts` fetch flow). Reads as a genuine run around the neighborhood; kept to ~58 points so
    /// one full lap draws + closes before the screenshot (each accepted fix triggers a live map sync).
    private static func landRoute() -> [(Double, Double)]? {
        [
        (37.78051, -122.47802), (37.78050, -122.47743), (37.78052, -122.47684), (37.78039, -122.47627),
        (37.78039, -122.47568), (37.78002, -122.47532), (37.77956, -122.47520), (37.77910, -122.47508),
        (37.77864, -122.47499), (37.77817, -122.47495), (37.77771, -122.47491), (37.77724, -122.47488),
        (37.77677, -122.47484), (37.77630, -122.47481), (37.77584, -122.47477), (37.77537, -122.47474),
        (37.77490, -122.47471), (37.77443, -122.47467), (37.77396, -122.47464), (37.77349, -122.47460),
        (37.77316, -122.47501), (37.77308, -122.47559), (37.77305, -122.47618), (37.77301, -122.47677),
        (37.77298, -122.47736), (37.77296, -122.47795), (37.77293, -122.47854), (37.77290, -122.47913),
        (37.77286, -122.47972), (37.77283, -122.48031), (37.77285, -122.48090), (37.77331, -122.48100),
        (37.77377, -122.48110), (37.77423, -122.48121), (37.77437, -122.48177), (37.77461, -122.48227),
        (37.77460, -122.48286), (37.77499, -122.48319), (37.77545, -122.48331), (37.77592, -122.48336),
        (37.77639, -122.48341), (37.77686, -122.48344), (37.77733, -122.48347), (37.77779, -122.48351),
        (37.77804, -122.48301), (37.77824, -122.48247), (37.77829, -122.48188), (37.77875, -122.48176),
        (37.77921, -122.48165), (37.77966, -122.48153), (37.78012, -122.48146), (37.78019, -122.48088),
        (37.78023, -122.48029), (37.78026, -122.47970), (37.78029, -122.47911), (37.78032, -122.47852),
        ]
    }

    /// Linearly interpolate a coarse route so consecutive points sit ~`everyMeters` apart — a dense,
    /// realistic GPS cadence (the raw loop's ~55 m hops would read as a jerky feed at 6:00/mi). Over
    /// ~55 m segments the great-circle curvature error is sub-metre, so straight lerp is fine here.
    private static func densify(_ pts: [(Double, Double)], everyMeters: Double) -> [(Double, Double)] {
        guard pts.count > 1, everyMeters > 0 else { return pts }
        var out: [(Double, Double)] = [pts[0]]
        for k in 1..<pts.count {
            let a = pts[k - 1], b = pts[k]
            let d = Geo.distance(lat1: a.0, lon1: a.1, lat2: b.0, lon2: b.1)
            let steps = max(1, Int((d / everyMeters).rounded()))
            for s in 1...steps {
                let f = Double(s) / Double(steps)
                out.append((a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f))
            }
        }
        return out
    }
#endif
}
