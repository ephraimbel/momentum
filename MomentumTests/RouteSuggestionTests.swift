import Testing
import Foundation
@testable import Momentum

/// `RouteSuggestionEngine` — the loop geometry + radius-convergence, driven by a mock router so the
/// math is validated with no network. Mirrors the GPS replay harness: synthetic "roads", real asserts.
struct RouteSuggestionTests {

    /// Mock roads: routed distance = crow-fly × a constant detour factor (roads are longer than the
    /// straight line); polyline is the straight segment. Linear in radius ⇒ the proportional
    /// correction must converge.
    struct MockDirections: DirectionsProviding {
        var detour = 1.3
        func walkingLeg(from: GeoPoint, to: GeoPoint) async throws -> RouteLeg {
            RouteLeg(distanceM: from.distance(to: to) * detour, polyline: [from, to])
        }
    }

    /// Nothing is routable here (every leg fails) — stands in for water / dead-ends.
    struct DeadZone: DirectionsProviding {
        func walkingLeg(from: GeoPoint, to: GeoPoint) async throws -> RouteLeg {
            throw RouteSuggestionError.noRoute
        }
    }

    let start = GeoPoint(lat: 37.7686, lon: -122.4830)

    @Test func convergesWithinTolerance() async throws {
        let engine = RouteSuggestionEngine(directions: MockDirections(detour: 1.4))
        let loop = try #require(await engine.suggestLoop(from: start, targetM: 5000, bearingSeed: 0))
        let err = abs(loop.distanceM - 5000) / 5000
        #expect(err <= 0.10, "loop \(loop.distanceM)m vs 5000m → \(err * 100)% off")
    }

    @Test func convergesAcrossDistances() async throws {
        let engine = RouteSuggestionEngine(directions: MockDirections(detour: 1.25))
        for target in [3_000.0, 5_000.0, 10_000.0] {
            let loop = try #require(await engine.suggestLoop(from: start, targetM: target, bearingSeed: 1))
            #expect(abs(loop.distanceM - target) / target <= 0.10)
        }
    }

    @Test func generatesDistinctLoops() async {
        let engine = RouteSuggestionEngine(directions: MockDirections())
        let loops = await engine.suggestLoops(from: start, targetM: 5000, count: 3)
        #expect(loops.count == 3)
        #expect(Set(loops.map(\.bearingSeed)).count == 3)              // distinct seeds → distinct loops
        for loop in loops { #expect(abs(loop.distanceM - 5000) / 5000 <= 0.10) }
    }

    @Test func loopReturnsToStart() async throws {
        let engine = RouteSuggestionEngine(directions: MockDirections())
        let loop = try #require(await engine.suggestLoop(from: start, targetM: 5000, bearingSeed: 0))
        let first = try #require(loop.polyline.first)
        let last = try #require(loop.polyline.last)
        #expect(first.distance(to: start) < 1)     // starts at the start
        #expect(last.distance(to: start) < 1)      // and returns to it
        #expect(loop.waypoints.count == 3)
    }

    @Test func unroutableAreaYieldsNoLoop() async {
        let engine = RouteSuggestionEngine(directions: DeadZone())
        #expect(await engine.suggestLoop(from: start, targetM: 5000, bearingSeed: 0) == nil)
        #expect(await engine.suggestLoops(from: start, targetM: 5000, count: 3).isEmpty)
    }

    @Test func destinationOffsetMatchesDistance() {
        let engine = RouteSuggestionEngine(directions: MockDirections())
        let p = engine.destination(from: start, bearingRad: .pi / 3, distanceM: 1000)
        #expect(abs(p.distance(to: start) - 1000) < 1)   // geodesic offset round-trips to ~1m
    }
}
