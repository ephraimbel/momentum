import Testing
import Foundation
import CoreLocation
@testable import Momentum

/// The incremental live smoother must be indistinguishable from the full recompute — chunks are
/// frozen and never re-sent, so any divergence would be permanently visible on the athlete's map.
struct LiveSmootherTests {

    /// Deterministic pseudo-random jittered path (no Math.random in tests — reproducibility).
    private func makeRoute(points: Int, seed: Int = 7) -> [CLLocationCoordinate2D] {
        var route: [CLLocationCoordinate2D] = []
        var lat = 30.2672, lon = -97.7431
        var state = UInt64(seed)
        func next() -> Double {   // xorshift → [-1, 1]
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(Int64(bitPattern: state % 2001) - 1000) / 1000.0
        }
        for _ in 0..<points {
            lat += 0.000045 + 0.000015 * next()   // ~5 m northward + lateral wobble
            lon += 0.000020 * next()
            route.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return route
    }

    /// Rebuild one continuous polyline from chunks + tail (adjacent pieces share their boundary point).
    private func reconstruct(chunks: [[CLLocationCoordinate2D]], tail: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for piece in chunks + [tail] {
            out.append(contentsOf: out.isEmpty ? piece : Array(piece.dropFirst()))
        }
        return out
    }

    @Test func incrementalMatchesFullRecompute() {
        let route = makeRoute(points: 400)
        var smoother = RouteSmoothing.LiveSmoother()
        // Feed point-by-point exactly like the live map does.
        for i in 1...route.count { _ = smoother.ingest(Array(route[0..<i])) }

        let incremental = reconstruct(chunks: smoother.allChunks, tail: smoother.tail)
        let full = RouteSmoothing.smooth(route)
        #expect(incremental.count == full.count)
        for (a, b) in zip(incremental, full) {
            #expect(abs(a.latitude - b.latitude) < 1e-12)
            #expect(abs(a.longitude - b.longitude) < 1e-12)
        }
    }

    @Test func batchedIngestMatchesPointByPoint() {
        let route = makeRoute(points: 300, seed: 21)
        var one = RouteSmoothing.LiveSmoother()
        for i in 1...route.count { _ = one.ingest(Array(route[0..<i])) }
        var batched = RouteSmoothing.LiveSmoother()
        _ = batched.ingest(Array(route[0..<120]))
        _ = batched.ingest(Array(route[0..<121]))   // overlapping re-pass reads only the new point
        _ = batched.ingest(route)
        let a = reconstruct(chunks: one.allChunks, tail: one.tail)
        let b = reconstruct(chunks: batched.allChunks, tail: batched.tail)
        #expect(a.count == b.count)
        for (p, q) in zip(a, b) {
            #expect(abs(p.latitude - q.latitude) < 1e-12)
            #expect(abs(p.longitude - q.longitude) < 1e-12)
        }
    }

    @Test func chunksAreEmittedAndNeverRevised() {
        let route = makeRoute(points: 200)
        var smoother = RouteSmoothing.LiveSmoother()
        var emitted: [[CLLocationCoordinate2D]] = []
        for i in 1...route.count {
            emitted.append(contentsOf: smoother.ingest(Array(route[0..<i])).newChunks)
        }
        #expect(!emitted.isEmpty)                       // long routes must freeze (that's the point)
        #expect(emitted.count == smoother.allChunks.count)
        for (e, kept) in zip(emitted, smoother.allChunks) {
            #expect(e.count == kept.count)              // what was emitted is exactly what's retained
        }
    }

    @Test func dataGapSplitsTheTraceInsteadOfChording() {
        // Two clusters ~500 m apart — a tunnel dropout. No rendered piece may bridge them.
        var route = makeRoute(points: 60)
        let jumped = route.last!
        var lat = jumped.latitude + 0.0045    // ~500 m jump
        for _ in 0..<60 {
            lat += 0.000045
            route.append(CLLocationCoordinate2D(latitude: lat, longitude: jumped.longitude))
        }
        var smoother = RouteSmoothing.LiveSmoother()
        for i in 1...route.count { _ = smoother.ingest(Array(route[0..<i])) }

        let boundary = jumped.latitude + 0.002   // midway through the gap
        for piece in smoother.allChunks + [smoother.tail] {
            let below = piece.contains { $0.latitude < boundary }
            let above = piece.contains { $0.latitude > boundary }
            #expect(!(below && above))   // no single polyline spans the gap
        }
    }

    @Test func shortSegmentsPassThroughUnsplined() {
        let route = makeRoute(points: 2)
        var smoother = RouteSmoothing.LiveSmoother()
        _ = smoother.ingest(route)
        #expect(smoother.tail.count == 2)   // same pass-through rule as smooth(_:) under 3 points
        #expect(smoother.allChunks.isEmpty)
    }
}
