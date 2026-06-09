import Foundation

/// Geodesic helpers for GPS distance.
enum Geo {
    static let earthRadiusM = 6_371_000.0

    /// Great-circle distance between two lat/lon points (haversine), in meters.
    static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadiusM * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
