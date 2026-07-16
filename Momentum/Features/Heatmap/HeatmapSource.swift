import Foundation
import SwiftData

/// Builds the personal-heatmap data from the athlete's own workouts. Faulting every run's GPS samples
/// is the heavy part, so it runs off the main actor on a fresh background context (only the store's
/// container + the details' persistent ids cross the hop — SwiftData models aren't `Sendable`), then
/// bins the coordinates. Shared by the full `PersonalHeatmapView` and the compact `HeatmapHistoryCard`
/// so the two never drift. The map fits the camera to the cells itself, so no region is computed here.
@MainActor
enum HeatmapSource {
    struct Result {
        let cells: [HeatCell]
        let activityCount: Int
        let totalMeters: Double
    }

    static func build(from workouts: [Workout]) async -> Result {
        let gps = workouts.compactMap(\.gps)
        // Cheap on the main actor: the details are already materialised and distanceM is a stored
        // scalar, so this faults no samples.
        let meters = gps.reduce(0) { $0 + $1.distanceM }
        let count = gps.count
        guard let container = gps.first?.modelContext?.container else {
            // No backing store (transient/preview objects): the samples are already in memory, so
            // read them inline — there's nothing to fault and nothing to stall.
            var coords: [GeoPoint] = []
            for detail in gps {
                for s in detail.samples where s.accepted { coords.append(GeoPoint(lat: s.lat, lon: s.lon)) }
            }
            return Result(cells: HeatmapBinning.bin(coords), activityCount: count, totalMeters: meters)
        }
        // Fault + flatten every accepted fix off the main actor so a large history never stalls the
        // heatmap surface. Binning is order-independent, so the cells are identical to the inline path.
        let ids = gps.map(\.persistentModelID)
        let binned = await Task.detached {
            let context = ModelContext(container)
            var coords: [GeoPoint] = []
            for id in ids {
                guard let detail = context.model(for: id) as? GPSDetail else { continue }
                for s in detail.samples where s.accepted { coords.append(GeoPoint(lat: s.lat, lon: s.lon)) }
            }
            return HeatmapBinning.bin(coords)
        }.value
        return Result(cells: binned, activityCount: count, totalMeters: meters)
    }
}
