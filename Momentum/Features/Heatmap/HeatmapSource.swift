import Foundation
import MapKit

/// Builds the personal-heatmap data from the athlete's own workouts: flatten the accepted GPS samples
/// on the main actor (SwiftData models aren't `Sendable`), then bin off it. Shared by the full
/// `PersonalHeatmapView` and the compact `HeatmapHistoryCard` so the two never drift.
@MainActor
enum HeatmapSource {
    struct Result {
        let cells: [HeatCell]
        let region: MKCoordinateRegion?
        let activityCount: Int
        let totalMeters: Double
    }

    static func build(from workouts: [Workout]) async -> Result {
        let gps = workouts.compactMap(\.gps)
        var coords: [GeoPoint] = []
        coords.reserveCapacity(gps.reduce(0) { $0 + $1.samples.count })
        var meters = 0.0
        for detail in gps {
            meters += detail.distanceM
            for s in detail.samples where s.accepted { coords.append(GeoPoint(lat: s.lat, lon: s.lon)) }
        }
        let binned = await Task.detached { HeatmapBinning.bin(coords) }.value
        return Result(cells: binned, region: region(for: coords), activityCount: gps.count, totalMeters: meters)
    }

    static func region(for coords: [GeoPoint]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.lat), lons = coords.map(\.lon)
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (maxLat - minLat) * 1.3),
                                    longitudeDelta: max(0.01, (maxLon - minLon) * 1.3))
        return MKCoordinateRegion(center: center, span: span)
    }
}
