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
        if Self.isUITestRoute {
            authorizationStatus = .authorizedWhenInUse
            lastLocation = CLLocationCoordinate2D(latitude: 37.7917, longitude: -122.3996)
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
        if Self.isUITestRoute { return simulatedRouteFixes() }
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

#if DEBUG
    /// Launched for the live-run UI test, which can't rely on a real CoreLocation feed in the sim.
    static var isUITestRoute: Bool { ProcessInfo.processInfo.arguments.contains("--ui-test-route") }

    /// Marketing shot: fast-forward the simulated run to a ~2 mi mid-run state (route drawn, distance
    /// well past 0.0) instead of the ~48 m a real-time feed reaches in a screenshot window.
    static var isMidway: Bool { ProcessInfo.processInfo.arguments.contains("--live-run-midway") }

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

    /// A clean, gently-organic ~2 mi closed loop through Golden Gate Park — the marketing live-run
    /// traces this. (The bundled community street routes all have out-and-back spurs that read as a
    /// choppy, broken trace; a smooth closed loop frames as one clean run instead.)
    private static func landRoute() -> [(Double, Double)]? {
        let centerLat = 37.7690, centerLon = -122.4838       // Golden Gate Park
        let radiusM = 520.0                                   // one lap ≈ 2.1 mi
        let n = 150
        let mPerDegLat = 111_000.0
        let mPerDegLon = 111_000.0 * cos(centerLat * .pi / 180)
        var pts: [(Double, Double)] = []
        for k in 0..<n {
            let a = Double(k) / Double(n) * 2 * .pi
            // A little radius variation so it reads as a run, not a perfect circle.
            let r = radiusM * (1 + 0.13 * sin(3 * a + 0.6) + 0.07 * cos(2 * a))
            pts.append((centerLat + (r * sin(a)) / mPerDegLat,
                        centerLon + (r * cos(a)) / mPerDegLon))
        }
        pts.append(pts[0])                                    // close the loop
        return pts
    }
#endif
}
