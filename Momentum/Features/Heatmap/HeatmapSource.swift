import Foundation

/// Builds the personal-heatmap data from the athlete's own workouts: flatten the accepted GPS samples
/// on the main actor (SwiftData models aren't `Sendable`), then bin off it. Shared by the full
/// `PersonalHeatmapView` and the compact `HeatmapHistoryCard` so the two never drift. The map fits
/// the camera to the cells itself, so no region is computed here.
@MainActor
enum HeatmapSource {
    struct Result {
        let cells: [HeatCell]
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
        return Result(cells: binned, activityCount: gps.count, totalMeters: meters)
    }
}
