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
    /// Held for the duration of a recording so location updates keep flowing when the app is
    /// backgrounded or the screen locks (PRD §8.3 — "never lose a workout"). With the iOS 17+
    /// `CLLocationUpdate.liveUpdates` API this session is *required* for background delivery: the
    /// `UIBackgroundModes: location` entitlement alone is not enough — without a live session iOS stops
    /// delivering fixes the instant we leave the foreground, which is what froze a run's route mid-lap.
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
        // Belt-and-suspenders for background delivery: the live-updates session (`startBackgroundUpdates`)
        // is the real mechanism, but these keep the classic manager path honest too and show the blue
        // "in use" pill. `allowsBackgroundLocationUpdates` requires the `location` UIBackgroundMode
        // (declared in Info.plist) — setting it without that entitlement would trap.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
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

    /// Begin a background-activity session so fixes keep arriving with the screen locked / app
    /// backgrounded. Idempotent — safe to call once recording is armed. Skipped when unauthorized (the
    /// session would immediately fail) and under UI-test routes (no real CoreLocation).
    func startBackgroundUpdates() {
#if DEBUG
        if Self.isUITestRoute { return }
#endif
        guard isAuthorized, backgroundSession == nil else { return }
        backgroundSession = CLBackgroundActivitySession()
    }

    /// Stream accepted-or-not raw fixes. The engine's `GPSProcessor` applies the accept gate.
    ///
    /// The `liveUpdates` sequence can end or throw on a transient CoreLocation interruption (a brief
    /// service reset, returning from a long background stretch). We **re-subscribe** rather than let the
    /// stream die, so a single hiccup never silently stops tracking for the rest of a run — the run only
    /// ends when the caller cancels (`stop()`) or the user has actually denied access.
    func fixes() -> AsyncStream<GPSProcessor.Fix> {
#if DEBUG
        if Self.isUITestRoute { return simulatedRouteFixes() }
#endif
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                while !Task.isCancelled {
                    if self.isDenied { break }   // genuinely no access — stop retrying, UI reflects it
                    do {
                        for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                            if Task.isCancelled { break }
                            // No usable position this cycle (stationary flag, or a dropped fix): don't
                            // yield, but keep the sequence alive — it resumes when a fix returns.
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
                        // Transient error — fall through to the re-subscribe backoff below.
                    }
                    if Task.isCancelled { break }
                    // Brief backoff before re-subscribing so a persistent failure can't hot-spin.
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

    /// A deterministic ~3 m/s northward track: tight-accuracy fixes every 0.5 s so the run engine
    /// locks GPS, leaves `.acquiring` for `.tracking`, and stays above the auto-pause speed gate —
    /// exactly the conditions the Pause/Resume control needs, with none of the sim's GPS flakiness.
    private func simulatedRouteFixes() -> AsyncStream<GPSProcessor.Fix> {
        AsyncStream { continuation in
            let task = Task {
                var lat = 37.7917
                let lon = -122.3996
                while !Task.isCancelled {
                    continuation.yield(GPSProcessor.Fix(
                        t: Date(), lat: lat, lon: lon,
                        accuracyM: 5, speedMS: 3, altitudeM: 0))
                    lat += 0.0000135   // ~1.5 m north per tick ≈ 3 m/s
                    try? await Task.sleep(for: .milliseconds(500))
                }
                continuation.finish()
            }
            self.streamTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#endif
}
