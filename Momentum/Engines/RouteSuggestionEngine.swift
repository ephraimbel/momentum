import Foundation

/// A plain lat/lon pair — `Sendable` so loops/legs cross the actor boundary cleanly (the codebase
/// deliberately avoids `CLLocationCoordinate2D` in concurrency contexts; convert at the MapKit edge).
struct GeoPoint: Sendable, Equatable, Hashable {
    let lat: Double
    let lon: Double

    /// Great-circle distance in metres (haversine).
    func distance(to o: GeoPoint) -> Double {
        let r = 6_371_000.0
        let dLat = (o.lat - lat) * .pi / 180, dLon = (o.lon - lon) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * .pi / 180) * cos(o.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// One routed leg between two points — only `Sendable` data extracted from MapKit's `MKRoute`.
struct RouteLeg: Sendable {
    let distanceM: Double
    let polyline: [GeoPoint]
}

/// A suggested run/walk/hike loop returning to its start.
struct SuggestedLoop: Sendable, Identifiable {
    let id = UUID()
    let polyline: [GeoPoint]      // assembled, path-snapped, start…→…start
    let waypoints: [GeoPoint]
    let distanceM: Double
    let bearingSeed: Double       // lets the UI "shuffle" to a different loop
}

/// Point-to-point routing, injected so the engine's geometry is unit-testable without the network
/// (same pattern as `GPSWorkoutSink`). The production adapter wraps `MKDirections`.
protocol DirectionsProviding: Sendable {
    func walkingLeg(from: GeoPoint, to: GeoPoint) async throws -> RouteLeg
}

enum RouteSuggestionError: Error { case noRoute }

/// Suggests **loops** of a target distance from a start point using only point-to-point directions
/// (MapKit has no native "make a loop"). It places waypoints on a circle through the start, routes
/// the ring on real paths via an injected `DirectionsProviding`, measures the routed distance, and
/// corrects the radius until the loop lands within tolerance — a deterministic geometry loop with the
/// routing call injected (PRD §9 ethos; the AI only *names* a loop, never computes it).
///
/// Apple-native only. Run/walk/hike only — MapKit has no cycling directions. Needs network at
/// suggestion time; recording stays offline-first.
actor RouteSuggestionEngine {
    private let directions: DirectionsProviding
    private var legCache: [LegKey: RouteLeg] = [:]

    init(directions: DirectionsProviding) { self.directions = directions }

    enum Const {
        static let waypoints = 3          // + the start = a 4-vertex polygon ≈ a circle
        static let tolerance = 0.10       // accept within ±10% of target
        static let maxIterations = 4      // request budget per loop
        static let earthRadiusM = 6_371_000.0
    }

    /// Generate up to `count` distinct loops by seeding evenly-spaced start bearings. `seedOffset`
    /// rotates the whole set — the UI bumps it to "shuffle" a fresh batch of loops.
    func suggestLoops(from start: GeoPoint, targetM: Double, count: Int = 3, seedOffset: Double = 0) async -> [SuggestedLoop] {
        var out: [SuggestedLoop] = []
        let n = max(1, count)
        for i in 0..<n {
            let seed = seedOffset + 2 * .pi * Double(i) / Double(n)
            if let loop = await suggestLoop(from: start, targetM: targetM, bearingSeed: seed) {
                out.append(loop)
            }
        }
        return out
    }

    /// One loop for a seed bearing. Returns the best attempt within the request budget, or nil if the
    /// area is unroutable (waypoints fall in water / dead-ends on every iteration).
    func suggestLoop(from start: GeoPoint, targetM: Double, bearingSeed: Double) async -> SuggestedLoop? {
        guard targetM > 0 else { return nil }
        var radius = targetM / (2 * .pi)         // a circle of circumference `targetM`
        var best: (loop: SuggestedLoop, err: Double)?

        for _ in 0..<Const.maxIterations {
            let waypoints = ring(start: start, radius: radius, seed: bearingSeed)
            let stops = [start] + waypoints + [start]
            guard let legs = await routeLegs(stops) else { break }   // unreachable ring → abandon seed
            let routedM = legs.reduce(0) { $0 + $1.distanceM }
            guard routedM > 0 else { break }

            let loop = assemble(legs: legs, waypoints: waypoints, distanceM: routedM, seed: bearingSeed)
            let err = abs(routedM - targetM) / targetM
            if best == nil || err < best!.err { best = (loop, err) }
            if err <= Const.tolerance { return loop }
            radius *= targetM / routedM                              // proportional correction
        }
        return best?.loop
    }

    // MARK: Geometry

    /// `waypoints` evenly spaced with the start around a circle of `radius` whose centre sits `radius`
    /// from the start along the seed bearing — so start→W1…→Wn→start is a real loop that returns home,
    /// not radial spokes through the centre.
    private func ring(start: GeoPoint, radius: Double, seed: Double) -> [GeoPoint] {
        let centre = destination(from: start, bearingRad: seed, distanceM: radius)
        let startAngle = seed + .pi              // bearing from centre back to the start
        let n = Const.waypoints + 1              // total vertices incl. the start
        return (1..<n).map { i in
            destination(from: centre, bearingRad: startAngle + 2 * .pi * Double(i) / Double(n), distanceM: radius)
        }
    }

    /// Geodesic destination point — offset `c` by `bearingRad` and `distanceM` on a sphere.
    nonisolated func destination(from c: GeoPoint, bearingRad b: Double, distanceM d: Double) -> GeoPoint {
        let angDist = d / Const.earthRadiusM
        let lat1 = c.lat * .pi / 180, lon1 = c.lon * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angDist) + cos(lat1) * sin(angDist) * cos(b))
        let lon2 = lon1 + atan2(sin(b) * sin(angDist) * cos(lat1),
                                cos(angDist) - sin(lat1) * sin(lat2))
        return GeoPoint(lat: lat2 * 180 / .pi, lon: lon2 * 180 / .pi)
    }

    // MARK: Routing

    private func routeLegs(_ stops: [GeoPoint]) async -> [RouteLeg]? {
        var legs: [RouteLeg] = []
        for i in 0..<(stops.count - 1) {
            guard let leg = await cachedLeg(from: stops[i], to: stops[i + 1]) else { return nil }
            legs.append(leg)
        }
        return legs
    }

    private func cachedLeg(from: GeoPoint, to: GeoPoint) async -> RouteLeg? {
        let key = LegKey(from: from, to: to)
        if let hit = legCache[key] { return hit }
        guard let leg = try? await directions.walkingLeg(from: from, to: to) else { return nil }
        legCache[key] = leg
        return leg
    }

    private func assemble(legs: [RouteLeg], waypoints: [GeoPoint], distanceM: Double, seed: Double) -> SuggestedLoop {
        var poly: [GeoPoint] = []
        for leg in legs {
            // each leg starts where the previous ended — drop the duplicated joint
            poly.append(contentsOf: poly.isEmpty ? leg.polyline : Array(leg.polyline.dropFirst()))
        }
        return SuggestedLoop(polyline: poly, waypoints: waypoints, distanceM: distanceM, bearingSeed: seed)
    }

    /// Quantises endpoints to ~1m so a retried leg hits the cache (helps the MapKit rate limit).
    private struct LegKey: Hashable {
        let a: Int, b: Int, c: Int, d: Int
        init(from: GeoPoint, to: GeoPoint) {
            func q(_ x: Double) -> Int { Int((x * 100_000).rounded()) }
            a = q(from.lat); b = q(from.lon); c = q(to.lat); d = q(to.lon)
        }
    }
}
