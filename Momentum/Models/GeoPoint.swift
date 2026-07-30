import Foundation
import CoreLocation

/// A plain lat/lon pair — the app's core coordinate value. `Sendable` so GPS traces cross the
/// actor boundary cleanly (the codebase deliberately avoids `CLLocationCoordinate2D` in
/// concurrency contexts; convert at the map/MapKit edge via `clCoordinate`).
struct GeoPoint: Sendable, Equatable, Hashable {
    let lat: Double
    let lon: Double

    /// Great-circle distance in metres (haversine).
    func distance(to o: GeoPoint) -> Double {
        let r = 6_371_000.0
        let dLat = (o.lat - lat) * .pi / 180, dLon = (o.lon - lon) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * .pi / 180) * cos(o.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

extension GeoPoint {
    /// Bridge to CoreLocation/Mapbox at the rendering edge.
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
