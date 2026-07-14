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
        let midway = Self.isMidway
        // Midway takes bigger, coarser steps (dt 2 s, ~5.7 m north) so ~560 fixes cover 2 mi — few
        // enough that the engine keeps up and the app stays responsive for the screenshot — while the
        // implied speed (≤ ~3 m/s) still clears the Doppler accept-gate. Normal mode keeps the fine
        // 0.5 s / 1.4 m track the Pause/Resume UI test depends on.
        let step = midway ? 0.0000768 : 0.0000128   // ~8.5 m vs ~1.4 m north per tick
        let dtick = midway ? 3.0 : 0.5               // dt keeps implied speed ~2.8 m/s (gate passes)
        let wob = midway ? 0.0002 : 0.00045
        return AsyncStream { continuation in
            let task = Task {
                var lat = 37.7917
                let lon = -122.3996
                let base = Date()
                var tick = 0.0
                var i = 0
                while !Task.isCancelled {
                    // Gentle east-west swing so the route shows real shape; lateral drift stays small
                    // enough that each jump remains consistent with the reported speed (Doppler-first).
                    let wobble = wob * sin(tick * .pi / 90)
                    let bursting = midway && i < 500          // ~2.0 mi after Kalman, then real-time tip
                    let t = midway ? base.addingTimeInterval(tick) : Date()
                    continuation.yield(GPSProcessor.Fix(
                        t: t, lat: lat, lon: lon + wobble,
                        accuracyM: 5, speedMS: 3, altitudeM: 0))
                    lat += step
                    tick += dtick
                    i += 1
                    try? await Task.sleep(for: .milliseconds(bursting ? 8 : 500))
                }
                continuation.finish()
            }
            self.streamTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#endif
}
