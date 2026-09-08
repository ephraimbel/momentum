import Foundation
import Testing
@testable import Momentum

@MainActor
struct CommunityRouteDiscoveryTests {
    @Test func distanceBucketsHaveNoGapsOrOverlap() {
        for unit in [DistanceUnit.metric, .imperial] {
            let edges = unit == .metric ? [5000.0, 10000, 20000] : [3.0, 6, 12].map { $0 * Formatters.metersPerMile }
            for edge in edges {
                for meters in [edge - 0.01, edge, edge + 0.01] {
                    let matches = CommunityRouteDistance.allCases.filter { $0 != .all && $0.contains(meters: meters, unit: unit) }
                    #expect(matches.count == 1)
                }
            }
            #expect(CommunityRouteDistance.medium.contains(meters: edges[0], unit: unit))
            #expect(CommunityRouteDistance.long.contains(meters: edges[1], unit: unit))
            #expect(CommunityRouteDistance.longer.contains(meters: edges[2], unit: unit))
            for invalid in [0.0, -1, .infinity, .nan] {
                #expect(!CommunityRouteDistance.allCases.contains { $0.contains(meters: invalid, unit: unit) })
            }
        }
    }

    @Test func collectionsPersistAndStayWithTheirProfile() throws {
        let suite = "CommunityCollectionsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = UUID(), other = UUID(), route = UUID(), secondRoute = UUID()
        let store = RouteCollectionStore(defaults: defaults)
        #expect(store.create(name: "No profile") == nil)
        store.load(profileID: profile)
        #expect(store.create(name: "  \n ") == nil)
        let easy = try #require(store.create(name: "  Easy days  "))
        let weekend = try #require(store.create(name: "Weekend"))
        store.add(routeID: route, to: easy)
        store.add(routeID: route, to: weekend)
        // Reusing an existing collection must add idempotently, never remove its saved route.
        #expect(store.create(name: "easy DAYS") == easy)
        store.add(routeID: route, to: easy)
        store.add(routeID: secondRoute, to: easy)
        let restored = RouteCollectionStore(defaults: defaults)
        restored.load(profileID: profile)
        #expect(restored.collections.count == 2)
        #expect(restored.collections[0].name == "Easy days")
        #expect(restored.collections[0].routeIDs == [route, secondRoute])
        restored.prune(validIDs: [route])
        #expect(restored.collections[0].routeIDs == [route])
        restored.remove(easy)
        #expect(restored.collections.first?.routeIDs == [route])
        restored.load(profileID: other)
        #expect(restored.collections.isEmpty)
        restored.load(profileID: profile)
        #expect(restored.collections.map(\.id) == [weekend])
        restored.toggle(routeID: route, in: weekend)
        #expect(restored.collections[0].routeIDs.isEmpty)
        defaults.set("keep", forKey: "unrelated")
        RouteCollectionStore.clearAll(defaults: defaults)
        restored.load(profileID: profile)
        #expect(restored.collections.isEmpty)
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }
    @Test func malformedSavedRoutesDoNotOpenInvalidMaps() {
        let route = SavedRoute(postID: UUID(), title: "Old save", authorName: "Runner",
                               authorHandle: nil, city: nil, km: 5,
                               pts: [[95, 0], [40], [40, -74], [40, -74]], mapStyle: .standard)
        #expect(!route.hasRoute, "Only one distinct valid point is not a route")
        #expect(route.coordinates.isEmpty)
        route.ptsJSON = Data("[[40,-74],[40.01,-74.01],[40.01,-74.01]]".utf8)
        #expect(route.hasRoute)
        #expect(route.coordinates.count == 2)
        route.ptsJSON = Data("not JSON".utf8)
        #expect(!route.hasRoute)
    }

}
