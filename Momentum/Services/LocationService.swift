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
        // interrupts the flow, and report authorized so the acquiring gate behaves normally.
        if Self.isUITestRoute { authorizationStatus = .authorizedWhenInUse; return }
#endif
        manager.requestWhenInUseAuthorization()
        if isAuthorized { manager.requestLocation() }   // one-shot fix to center the home map
    }

    /// Ask for a single fresh fix (used to recenter the home map on demand).
    func refreshLocation() {
        guard isAuthorized else { return }
        manager.requestLocation()
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
        return AsyncStream { continuation in
            let task = Task {
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
                    // Authorization denied / transient error: end the stream; UI reflects state.
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
