import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import Momentum

/// Scale + downsampling checks for history (PRD §13.1: jank-free at 1000+ items). FPS itself is a
/// device measure; here we confirm the data layer aggregates 1000 workouts correctly and that
/// route-silhouette thumbnails are point-capped so list cells stay cheap.
@MainActor
struct ScaleTests {

    @Test func aggregatesThousandWorkouts() throws {
        let schema = Schema(PersistenceController.models)
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let ctx = container.mainContext

        let base = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<1000 {
            let w = Workout()
            w.startedAt = base.addingTimeInterval(Double(i) * 3600)
            w.durationS = 1800
            if i.isMultiple(of: 2) {
                w.type = .run
                let gps = GPSDetail(); gps.distanceM = 5000; w.gps = gps
            } else {
                w.type = .strength
                let s = StrengthSession(); s.totalVolumeKg = 1000; s.totalSets = 10; w.strength = s
            }
            ctx.insert(w)
        }
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Workout>())
        #expect(all.count == 1000)
        let stats = ProfileStats(workouts: all)
        #expect(stats.totalWorkouts == 1000)
        #expect(stats.countsByType[.run] == 500)
        #expect(stats.countsByType[.strength] == 500)
        #expect(stats.totalDistanceM == 500 * 5000)
    }

    @Test func silhouetteDownsamplesAndKeepsEndpoints() {
        let coords = (0..<1000).map { CLLocationCoordinate2D(latitude: Double($0) * 0.0001, longitude: 0) }
        let reduced = RouteSilhouette.downsample(coords, to: 120)
        #expect(reduced.count == 120)
        #expect(reduced.first?.latitude == coords.first?.latitude)
        #expect(reduced.last?.latitude == coords.last?.latitude)

        // Small routes are returned untouched.
        let small = Array(coords.prefix(50))
        #expect(RouteSilhouette.downsample(small, to: 120).count == 50)
    }
}
