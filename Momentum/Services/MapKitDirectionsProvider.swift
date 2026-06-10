import Foundation
import MapKit

/// `DirectionsProviding` backed by Apple's `MKDirections` (walking — the closest native mode to
/// running on foot; MapKit has no cycling). Extracts only `Sendable` data (distance + coordinates)
/// from the non-`Sendable` `MKRoute` before returning, so it crosses the engine's actor boundary
/// cleanly. Throttle/transient/no-route errors surface as a throw; `RouteSuggestionEngine` degrades.
struct MapKitDirectionsProvider: DirectionsProviding {
    func walkingLeg(from: GeoPoint, to: GeoPoint) async throws -> RouteLeg {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.clCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.clCoordinate))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw RouteSuggestionError.noRoute }
        let coords = route.polyline.coordinates.map { GeoPoint(lat: $0.latitude, lon: $0.longitude) }
        return RouteLeg(distanceM: route.distance, polyline: coords)
    }
}

extension GeoPoint {
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

private extension MKPolyline {
    /// MapKit only exposes points via a C buffer — read them out into `CLLocationCoordinate2D`.
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
