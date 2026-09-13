import CoreLocation

/// North-up, zero-pitch camera fitting needs geographic extrema, not every recorded GPS point.
/// Keep the actual route intact for drawing. Mapbox's overview state reprojects its geometry
/// whenever the view size changes (MOMENTUM-IOS-Q); bound that bridge work to six coordinates.
enum RouteCameraBounds {
    static func coordinates(_ route: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        let points = route.filter { CLLocationCoordinate2DIsValid($0) }
        guard points.count > 6 else { return points }
        var north = 0, south = 0, east = 0, west = 0
        for i in points.indices.dropFirst() {
            if points[i].latitude > points[north].latitude { north = i }
            if points[i].latitude < points[south].latitude { south = i }
            if points[i].longitude > points[east].longitude { east = i }
            if points[i].longitude < points[west].longitude { west = i }
        }
        // Preserve Mapbox's full wrap-selection input for dateline-spanning routes.
        guard points[east].longitude - points[west].longitude <= 180 else { return points }
        return Set([0, points.count - 1, north, south, east, west]).sorted().map { points[$0] }
    }
}
