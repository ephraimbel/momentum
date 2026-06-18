import Testing
import Foundation
@testable import Momentum

/// Pure tests for the running/hiking-spots pipeline (PRD §6): parsing real Mapbox Search JSON, the
/// dedupe, the Run/Hike filter, and the nearness+popularity ranking. No network.
struct SpotsTests {

    // A trimmed but real Mapbox Search Box category response (downtown Austin parks).
    static let parkJSON = """
    {"features":[
      {"properties":{"name":"Republic Square","mapbox_id":"id-republic",
        "coordinates":{"latitude":30.26775,"longitude":-97.74694},
        "context":{"neighborhood":{"name":"Downtown"},"place":{"name":"Austin"}}}},
      {"properties":{"name":"Wooldridge Square","mapbox_id":"id-wooldridge",
        "coordinates":{"latitude":30.27233,"longitude":-97.7453},
        "context":{"neighborhood":{"name":"Downtown"},"place":{"name":"Austin"}}}}
    ]}
    """

    @Test func parsesRealMapboxJSON() {
        let spots = MapboxSpotsProvider.parse(Data(Self.parkJSON.utf8), kind: .park)
        #expect(spots.count == 2)
        let first = spots[0]
        #expect(first.name == "Republic Square")
        #expect(first.id == "id-republic")
        #expect(first.kind == .park)
        #expect(first.neighborhood == "Downtown")
        #expect(abs(first.point.lat - 30.26775) < 1e-6)
        #expect(abs(first.point.lon - (-97.74694)) < 1e-6)
    }

    @Test func skipsFeaturesMissingNameOrCoords() {
        let json = """
        {"features":[
          {"properties":{"mapbox_id":"x","coordinates":{"latitude":1,"longitude":2}}},
          {"properties":{"name":"No coords"}},
          {"properties":{"name":"Good","mapbox_id":"g","coordinates":{"latitude":1,"longitude":2}}}
        ]}
        """
        let spots = MapboxSpotsProvider.parse(Data(json.utf8), kind: .trail)
        #expect(spots.count == 1)
        #expect(spots[0].name == "Good")
    }

    @Test func dedupesByIDAndNearbyCoordinate() {
        let a = Spot(id: "1", name: "Park", kind: .park, point: GeoPoint(lat: 30.0, lon: -97.0), neighborhood: nil, distanceM: 0)
        let dupID = Spot(id: "1", name: "Park again", kind: .natureReserve, point: GeoPoint(lat: 31, lon: -98), neighborhood: nil, distanceM: 0)
        let dupCoord = Spot(id: "2", name: "Same place, other category", kind: .natureReserve, point: GeoPoint(lat: 30.00001, lon: -97.00001), neighborhood: nil, distanceM: 0)
        let far = Spot(id: "3", name: "Elsewhere", kind: .forest, point: GeoPoint(lat: 40, lon: -100), neighborhood: nil, distanceM: 0)
        let out = MapboxSpotsProvider.dedupe([a, dupID, dupCoord, far])
        #expect(out.count == 2)                          // a (+ its id/coord dups collapsed) and far
        #expect(out.map(\.id).sorted() == ["1", "3"])
    }

    // MARK: Ranking

    private static let origin = GeoPoint(lat: 30.2672, lon: -97.7431)

    @Test func ranksNearerFirstAndFillsDistance() {
        let near = Spot(id: "near", name: "Near park", kind: .park, point: GeoPoint(lat: 30.2680, lon: -97.7440), neighborhood: nil, distanceM: 0)
        let far = Spot(id: "far", name: "Far park", kind: .park, point: GeoPoint(lat: 30.40, lon: -97.90), neighborhood: nil, distanceM: 0)
        let ranked = SpotRanker.rank([far, near], from: Self.origin, activity: nil)
        #expect(ranked.first?.id == "near")
        #expect(ranked.first!.distanceM > 0)             // distance got filled
        #expect(ranked.first!.distanceM < ranked.last!.distanceM)
    }

    @Test func runHikeFilterIncludesOnlyMatchingKinds() {
        let park = Spot(id: "p", name: "Park", kind: .park, point: Self.origin, neighborhood: nil, distanceM: 0)        // run only
        let mountain = Spot(id: "m", name: "Peak", kind: .mountain, point: Self.origin, neighborhood: nil, distanceM: 0) // hike only
        let trail = Spot(id: "t", name: "Trail", kind: .trail, point: Self.origin, neighborhood: nil, distanceM: 0)      // both

        let runOnly = SpotRanker.rank([park, mountain, trail], from: Self.origin, activity: .run).map(\.id)
        #expect(Set(runOnly) == ["p", "t"])
        let hikeOnly = SpotRanker.rank([park, mountain, trail], from: Self.origin, activity: .hike).map(\.id)
        #expect(Set(hikeOnly) == ["m", "t"])
    }

    @Test func dropsSpotsBeyondRadius() {
        let near = Spot(id: "n", name: "Near", kind: .park, point: GeoPoint(lat: 30.27, lon: -97.74), neighborhood: nil, distanceM: 0)
        let veryFar = Spot(id: "f", name: "Far", kind: .park, point: GeoPoint(lat: 34.0, lon: -118.0), neighborhood: nil, distanceM: 0) // LA
        let ranked = SpotRanker.rank([near, veryFar], from: Self.origin, activity: nil, maxRadiusM: 40_000)
        #expect(ranked.map(\.id) == ["n"])
    }

    @Test func popularityBumpsButNearnessLeads() {
        // Two parks: a near one (unknown) and a slightly farther very-popular one. A modest popularity
        // bump shouldn't flip a clearly-nearer spot…
        let near = Spot(id: "near", name: "Near", kind: .park, point: GeoPoint(lat: 30.2682, lon: -97.7441), neighborhood: nil, distanceM: 0)
        let popularFar = Spot(id: "pop", name: "Popular", kind: .park, point: GeoPoint(lat: 30.30, lon: -97.78), neighborhood: nil, distanceM: 0)
        let ranked = SpotRanker.rank([near, popularFar], from: Self.origin, activity: nil,
                                     popularity: ["pop": .community(runs: 500)])
        #expect(ranked.first?.id == "near")
        #expect(ranked.first(where: { $0.id == "pop" })?.popularity.isPopular == true)
    }
}
