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

    @Test func streamsDistinctLoopsProgressively() async {
        let engine = RouteSuggestionEngine(directions: MockDirections())
        var loops: [SuggestedLoop] = []
        for await loop in engine.suggestLoopsStream(from: start, targetM: 5000, count: 3) {
            loops.append(loop)
        }
        #expect(loops.count == 3)                                      // yields up to `count` distinct loops
        #expect(Set(loops.map(\.bearingSeed)).count == 3)
        for loop in loops { #expect(abs(loop.distanceM - 5000) / 5000 <= 0.10) }
    }

    @Test func streamYieldsNothingInUnroutableArea() async {
        let engine = RouteSuggestionEngine(directions: DeadZone())
        var count = 0
        for await _ in engine.suggestLoopsStream(from: start, targetM: 5000, count: 3) { count += 1 }
        #expect(count == 0)
    }

    @Test func loopReturnsToStart() async throws {
        let engine = RouteSuggestionEngine(directions: MockDirections())
        let loop = try #require(await engine.suggestLoop(from: start, targetM: 5000, bearingSeed: 0))
        let first = try #require(loop.polyline.first)
        let last = try #require(loop.polyline.last)
        #expect(first.distance(to: start) < 1)     // starts at the start
        #expect(last.distance(to: start) < 1)      // and returns to it
        #expect(loop.waypoints.count == 4)         // 4 waypoints + start ≈ a rounder pentagon
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

    // MARK: Loop quality (shape) — pure, no routing

    /// A ~200 m square loop, optionally shifted, tagged via `bearingSeed` so tests can identify it.
    private func squareLoop(_ tag: Double, distanceM: Double, dLat: Double = 0, dLon: Double = 0) -> SuggestedLoop {
        let s = 0.0018   // ≈ 200 m
        let poly = [(0.0, 0.0), (0.0, s), (s, s), (s, 0.0), (0.0, 0.0)]
            .map { GeoPoint(lat: $0.0 + dLat, lon: $0.1 + dLon) }
        return SuggestedLoop(polyline: poly, waypoints: [], distanceM: distanceM, bearingSeed: tag)
    }

    private func outAndBack(_ tag: Double, distanceM: Double) -> SuggestedLoop {
        let poly = [GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 0, lon: 0.0018), GeoPoint(lat: 0, lon: 0)]
        return SuggestedLoop(polyline: poly, waypoints: [], distanceM: distanceM, bearingSeed: tag)
    }

    @Test func roundnessSeparatesLoopsFromOutAndBacks() {
        #expect(LoopQuality.roundness(squareLoop(0, distanceM: 0).polyline) > 0.7)   // a real loop
        #expect(LoopQuality.roundness(outAndBack(0, distanceM: 0).polyline) < 0.05)  // degenerate
    }

    @Test func pickBestDropsOutAndBacks() {
        let round = squareLoop(1, distanceM: 5000)
        let bad = outAndBack(2, distanceM: 5000)
        let result = RouteSuggestionEngine.pickBest([bad, round], targetM: 5000, count: 2)
        #expect(result.map(\.bearingSeed) == [1])   // only the round loop survives the quality gate
    }

    @Test func pickBestDedupesSamePlace() {
        let better = squareLoop(1, distanceM: 5000)   // err 0 → higher score
        let worse = squareLoop(2, distanceM: 5500)    // same place, err 0.1 → lower score
        let result = RouteSuggestionEngine.pickBest([worse, better], targetM: 5000, count: 2)
        #expect(result.map(\.bearingSeed) == [1])     // same centroid → keep one (the better)
    }

    @Test func pickBestKeepsDistinctLoops() {
        let here = squareLoop(1, distanceM: 5000)
        let far = squareLoop(2, distanceM: 5000, dLat: 0.02)   // ~2.2 km away → genuinely different
        let result = RouteSuggestionEngine.pickBest([here, far], targetM: 5000, count: 2)
        #expect(Set(result.map(\.bearingSeed)) == [1, 2])
    }
}
