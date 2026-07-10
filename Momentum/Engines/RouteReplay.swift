import Foundation
import CoreLocation

/// Rebuilds a finished workout's display route from its persisted samples, applying the **same**
/// real-time Kalman filter the live run used (`GPSKalmanFilter`). Because that filter is causal,
/// replaying the stored accepted samples reproduces the exact track the athlete watched being drawn —
/// so the summary, history, share card, and profile art all show one consistent, smoothed route (§8.3,
/// §8.5). Distance is untouched: it's the value the engine accumulated live and persisted on the row.
extension GPSDetail {

    /// The best available route geometry: the Mapbox map-matched track when present (§8.5), otherwise
    /// the accepted samples Kalman-corrected into route coordinates. Pass the workout's discipline so
    /// the filter tunes to it (cyclists change speed faster than walkers); defaults to running. Feed
    /// the result to `RouteSmoothing.smooth` for the final display spline.
    func routeCoordinates(type: WorkoutType = .run) -> [CLLocationCoordinate2D] {
        if let matched = matchedCoordinates, matched.count > 1 { return matched }
        let accepted = samples.filter(\.accepted).sorted { $0.t < $1.t }
        guard accepted.count > 1 else {
            return accepted.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
        let input = accepted.map { (t: $0.t, lat: $0.lat, lon: $0.lon, accuracyM: $0.accuracyM) }
        return GPSKalmanFilter.smooth(input, config: .forType(type))
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// The stored Mapbox map-matched route (JSON `[[lat, lon]]`), or nil if matching never ran or was
    /// discarded below the confidence gate.
    private var matchedCoordinates: [CLLocationCoordinate2D]? {
        guard let data = matchedRouteData,
              let pairs = try? JSONDecoder().decode([[Double]].self, from: data), pairs.count > 1 else { return nil }
        return pairs.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }
}
