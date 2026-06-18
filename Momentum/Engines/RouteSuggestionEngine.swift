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
        static let waypoints = 4          // + the start = a 5-vertex polygon ≈ a circle (rounder loops)
        static let tolerance = 0.10       // accept within ±10% of target
        static let maxIterations = 4      // request budget per loop
        // Loops routing at once. Legs within a loop already route in parallel (~5 calls), so we route
        // candidates one at a time: the first loop gets MapKit's full bandwidth (fast), the rest stream
        // in right after, and we never exceed ~5 concurrent calls — staying well under MapKit's throttle.
        static let maxConcurrent = 1
        static let earthRadiusM = 6_371_000.0
        /// Reject loops below this roundness (isoperimetric) — degenerate out-and-backs (PRD §6).
        static let minRoundness = 0.12
        /// Two loops whose centroids sit within `targetM · this` read as the "same" route — dedupe them.
        static let distinctCentroidFraction = 0.12
    }

    /// Suggest `count` **distinct, well-shaped** loops. Oversamples seed bearings (routed in parallel),
    /// then keeps the roundest, most distance-accurate, visibly-different loops — so a lopsided or
    /// out-and-back candidate loses to a rounder one instead of being shown. `seedOffset` rotates the
    /// whole set so the UI can "shuffle" a fresh batch.
    func suggestLoops(from start: GeoPoint, targetM: Double, count: Int = 3, seedOffset: Double = 0) async -> [SuggestedLoop] {
        guard count > 0 else { return [] }
        let samples = max(count + 2, 5)                 // oversample, then pick the best `count`
        let seeds = (0..<samples).map { seedOffset + 2 * .pi * Double($0) / Double(samples) }
        // Route candidates concurrently but **bounded** — MapKit throttles bursts of directions calls,
        // so we keep at most `maxConcurrent` loops routing at once (fast, without tripping the throttle).
        var built: [SuggestedLoop] = []
        await withTaskGroup(of: SuggestedLoop?.self) { group in
            var next = 0
            func enqueue() {
                guard next < seeds.count else { return }
                let seed = seeds[next]; next += 1
                group.addTask { await self.suggestLoop(from: start, targetM: targetM, bearingSeed: seed) }
            }
            for _ in 0..<min(Const.maxConcurrent, seeds.count) { enqueue() }
            while let loop = await group.next() {
                if let loop { built.append(loop) }
                enqueue()                               // backfill as each finishes
            }
        }
        return Self.pickBest(built, targetM: targetM, count: count)
    }

    /// Streaming variant — **yields each distinct, well-shaped loop the moment it routes**, so the UI
    /// can show the first loop immediately and fill the rest in (no waiting for the whole batch). Skips
    /// degenerate out-and-backs and near-duplicates, stops after `count` distinct loops, and uses the
    /// same bounded concurrency (MapKit throttle). If the quality gate rejects everything but loops did
    /// route, it falls back to `pickBest` so a routable area never shows "no loop".
    nonisolated func suggestLoopsStream(from start: GeoPoint, targetM: Double, count: Int = 3, seedOffset: Double = 0) -> AsyncStream<SuggestedLoop> {
        AsyncStream { continuation in
            let task = Task {
                guard count > 0 else { continuation.finish(); return }
                let samples = max(count + 2, 5)
                let seeds = (0..<samples).map { seedOffset + 2 * .pi * Double($0) / Double(samples) }
                var shown: [SuggestedLoop] = []
                var routed: [SuggestedLoop] = []
                await withTaskGroup(of: SuggestedLoop?.self) { group in
                    var next = 0
                    func enqueue() {
                        guard next < seeds.count else { return }
                        let seed = seeds[next]; next += 1
                        group.addTask { await self.suggestLoop(from: start, targetM: targetM, bearingSeed: seed) }
                    }
                    for _ in 0..<min(Const.maxConcurrent, seeds.count) { enqueue() }
                    while let result = await group.next() {
                        if let loop = result {
                            routed.append(loop)
                            if LoopQuality.roundness(loop.polyline) >= Const.minRoundness,
                               shown.allSatisfy({ Self.centroidDistance($0, loop) > targetM * Const.distinctCentroidFraction }) {
                                shown.append(loop)
                                continuation.yield(loop)        // show it right away
                                if shown.count >= count { break }
                            }
                        }
                        enqueue()
                    }
                    group.cancelAll()
                }
                if shown.isEmpty {                                  // gate rejected all — best effort
                    for loop in Self.pickBest(routed, targetM: targetM, count: count) { continuation.yield(loop) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Rank candidates by roundness (lead) and distance accuracy, drop degenerate out-and-backs, and
    /// keep only visibly-distinct loops. Pure + deterministic, so it's unit-testable without routing.
    static func pickBest(_ loops: [SuggestedLoop], targetM: Double, count: Int) -> [SuggestedLoop] {
        let ranked = loops.sorted { score($0, targetM: targetM) > score($1, targetM: targetM) }
        func takeDistinct(from pool: [SuggestedLoop]) -> [SuggestedLoop] {
            var kept: [SuggestedLoop] = []
            for loop in pool where kept.allSatisfy({ centroidDistance($0, loop) > targetM * Const.distinctCentroidFraction }) {
                kept.append(loop)
                if kept.count == count { break }
            }
            return kept
        }
        // Prefer real loops; if every candidate is weak, still return the best distinct ones (never
        // show "no loops" when routing actually succeeded).
        let good = ranked.filter { LoopQuality.roundness($0.polyline) >= Const.minRoundness }
        let kept = takeDistinct(from: good)
        return kept.isEmpty ? takeDistinct(from: ranked) : kept
    }

    /// Higher = better. Roundness leads; backtracking and distance error subtract.
    static func score(_ loop: SuggestedLoop, targetM: Double) -> Double {
        let roundness = LoopQuality.roundness(loop.polyline)
        let backtrack = LoopQuality.backtrackFraction(loop.polyline)
        let distErr = targetM > 0 ? abs(loop.distanceM - targetM) / targetM : 1
        return roundness - 0.6 * backtrack - 0.4 * distErr
    }

    static func centroidDistance(_ a: SuggestedLoop, _ b: SuggestedLoop) -> Double {
        LoopQuality.centroid(a.polyline).distance(to: LoopQuality.centroid(b.polyline))
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

    /// Route a ring's legs **in parallel** (they're independent), so one loop comes back in ~a single
    /// round-trip instead of N sequential ones — this is what makes the *first* loop appear fast. Cache
    /// hits are taken first; only the misses hit the network, and throttled calls retry in the provider.
    private func routeLegs(_ stops: [GeoPoint]) async -> [RouteLeg]? {
        var results = [RouteLeg?](repeating: nil, count: stops.count - 1)
        var misses: [(idx: Int, from: GeoPoint, to: GeoPoint)] = []
        for i in 0..<(stops.count - 1) {
            if let hit = legCache[LegKey(from: stops[i], to: stops[i + 1])] { results[i] = hit }
            else { misses.append((i, stops[i], stops[i + 1])) }
        }
        if !misses.isEmpty {
            let dir = directions
            let fetched = await withTaskGroup(of: (Int, RouteLeg?).self) { group in
                for m in misses {
                    group.addTask { (m.idx, try? await dir.walkingLeg(from: m.from, to: m.to)) }
                }
                var acc: [(Int, RouteLeg?)] = []
                for await pair in group { acc.append(pair) }
                return acc
            }
            for (idx, leg) in fetched {
                guard let leg else { return nil }                  // any unroutable leg → abandon the ring
                results[idx] = leg
                legCache[LegKey(from: stops[idx], to: stops[idx + 1])] = leg
            }
        }
        return results.contains(where: { $0 == nil }) ? nil : results.map { $0! }
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
