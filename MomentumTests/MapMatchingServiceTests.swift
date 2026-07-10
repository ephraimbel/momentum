import Testing
import Foundation
import CoreLocation
@testable import Momentum

/// `MapMatchingService` — Stage 3 snap-to-network (PRD §8.5). The network call isn't exercised here;
/// these pin the pure helpers that shape the request and read the response: profile choice,
/// downsampling, chunking to the 100-point limit, and parsing (including the confidence gate's input).
struct MapMatchingServiceTests {
    let base = CLLocationCoordinate2D(latitude: 37.7686, longitude: -122.4830)

    func east(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude,
                               longitude: base.longitude + meters / (111_320 * cos(base.latitude * .pi / 180)))
    }

    @Test func profileMapsFootSportsToWalkingAndBikesToCycling() {
        #expect(MapMatchingService.profile(for: .run) == .walking)
        #expect(MapMatchingService.profile(for: .walk) == .walking)
        #expect(MapMatchingService.profile(for: .ride) == .cycling)
    }

    @Test func downsampleThinsToSpacingAndKeepsEndpoints() {
        // 100 points 5m apart → ~495m; at 18m spacing expect far fewer, with both ends retained.
        let dense = (0..<100).map { east(Double($0) * 5) }
        let thin = MapMatchingService.downsample(dense, minSpacingM: 18)
        #expect(thin.count < dense.count)
        #expect(thin.count > 5)
        #expect(thin.first!.longitude == dense.first!.longitude)
        #expect(thin.last!.longitude == dense.last!.longitude)
        // Every kept gap (except possibly the last, which is forced) clears the spacing floor.
        for i in 1..<(thin.count - 1) {
            let d = Geo.distance(lat1: thin[i - 1].latitude, lon1: thin[i - 1].longitude,
                                 lat2: thin[i].latitude, lon2: thin[i].longitude)
            #expect(d >= 18 - 0.001)
        }
    }

    @Test func chunkRespectsLimitAndCoversEveryPoint() {
        let coords = (0..<250).map { east(Double($0) * 20) }
        let chunks = MapMatchingService.chunk(coords, maxPerRequest: 100, overlap: 1)
        #expect(chunks.allSatisfy { $0.count <= 100 })
        #expect(chunks.count == 3)
        // The union of chunk longitudes covers all 250 originals (overlap only duplicates seams).
        let covered = Set(chunks.flatMap { $0 }.map { $0.longitude })
        #expect(covered.count == 250)
        // Consecutive chunks share exactly the overlap point at the seam.
        #expect(chunks[0].last!.longitude == chunks[1].first!.longitude)
    }

    @Test func shortInputIsNotChunked() {
        let coords = (0..<10).map { east(Double($0) * 20) }
        #expect(MapMatchingService.chunk(coords, maxPerRequest: 100, overlap: 1).count == 1)
    }

    @Test func parsesValidResponseWithConfidence() {
        let json = """
        {"code":"Ok","matchings":[{"confidence":0.87,"geometry":{"coordinates":[[-122.483,37.7686],[-122.4825,37.769],[-122.482,37.7694]]}}]}
        """.data(using: .utf8)!
        let match = MapMatchingService.parse(json)
        #expect(match?.coordinates.count == 3)
        #expect(abs((match?.confidence ?? 0) - 0.87) < 1e-9)
        // GeoJSON is [lon, lat]; we must read it back as (lat, lon).
        #expect(abs((match?.coordinates.first?.latitude ?? 0) - 37.7686) < 1e-9)
        #expect(abs((match?.coordinates.first?.longitude ?? 0) - (-122.483)) < 1e-9)
    }

    @Test func rejectsNonOkResponse() {
        let json = #"{"code":"NoMatch","matchings":[]}"#.data(using: .utf8)!
        #expect(MapMatchingService.parse(json) == nil)
    }
}
