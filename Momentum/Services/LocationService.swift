import Foundation
import CoreLocation

/// Live GPS source (PRD §8.3). Uses the iOS 17+ `CLLocationUpdate.liveUpdates` async sequence —
/// no delegate, concurrency-clean — and a `CLLocationManager` only for authorization. Emits
/// `GPSProcessor.Fix` values; the cardio view model pumps these into `GPSTrackingEngine`.
@MainActor
final class LocationService: LocationServing {
    private let manager = CLLocationManager()
    private var streamTask: Task<Void, Never>?

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Stream accepted-or-not raw fixes. The engine's `GPSProcessor` applies the accept gate.
    func fixes() -> AsyncStream<GPSProcessor.Fix> {
        AsyncStream { continuation in
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
}
