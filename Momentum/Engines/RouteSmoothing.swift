import Foundation
import CoreLocation

/// Centripetal Catmull-Rom spline smoothing for GPS route polylines (PRD §8.5 — the Strava-smooth
/// trace).
///
/// Accepted fixes are deliberately **sparse** — `GPSProcessor` only appends a route point once
/// movement clears the 2m gate (`minMovementGateM`) — so the raw polyline renders as hard angles at
/// every turn. Passing the points through a spline rounds those corners into the fluid,
/// hand-drawn-looking track users expect, with **no effect on distance**: distance is accumulated
/// upstream in `GPSProcessor` from the raw fixes, never measured off this rendered line.
///
/// Two properties make the curve read as "perfect" rather than stiff-or-glitchy:
///  1. **Centripetal parameterization (α = 0.5).** A uniform Catmull-Rom overshoots on sharp turns
///     and unevenly-spaced points, producing cusps and little self-intersecting loops (the "glitch").
///     Centripetal spacing is provably free of cusps and self-intersections, so every corner curves
///     cleanly no matter the point spacing.
///  2. **Equirectangular longitude correction.** A degree of longitude is shorter than a degree of
///     latitude everywhere but the equator, so splining raw lat/lon warps the curve. We spline in a
///     local planar frame (longitude scaled by cos(latitude)) and unproject — so the geometry the
///     spline sees matches the ground.
///
/// Pure and free of UIKit — used by the live map, the history map, and the saved snapshot so all
/// three read identically.
enum RouteSmoothing {

    /// Interpolate a centripetal Catmull-Rom spline through `coords`. Returns the input unchanged for
    /// fewer than three points (a spline needs a neighbor on each side).
    /// - Parameter subdivisions: interpolated segments inserted per input span; higher = smoother and
    ///   denser. 6 reads fluid at running point density without bloating the polyline.
    static func smooth(_ coords: [CLLocationCoordinate2D], subdivisions: Int = 6) -> [CLLocationCoordinate2D] {
        guard coords.count >= 3, subdivisions >= 1 else { return coords }

        // Work in a local planar frame so distances (which drive the centripetal knot spacing) and
        // the curve itself are geometrically correct. Reference latitude anchors the longitude scale.
        let refLatRad = coords[0].latitude * .pi / 180
        let lonScale = cos(refLatRad)
        var pts = coords.map { Point(x: $0.longitude * lonScale, y: $0.latitude) }

        // Drop consecutive near-coincident points: a zero-length span makes the centripetal knot
        // spacing degenerate. `minMovementGateM` keeps real points ≥2m apart, so this only removes
        // exact duplicates (e.g. a stalled fix appended twice).
        pts = dedupe(pts)
        guard pts.count >= 3 else { return coords }

        // Denoise before interpolating so the spline rounds a clean path instead of faithfully
        // tracing through within-gate GPS wobble.
        pts = denoise(pts)

        var out: [Point] = []
        out.reserveCapacity((pts.count - 1) * subdivisions + 1)
        let n = pts.count
        for i in 0..<(n - 1) {
            // Phantom endpoints by reflection give the spline a natural tangent at the ends without a
            // degenerate (zero-length) knot span.
            let p0 = i - 1 >= 0 ? pts[i - 1] : Point(x: 2 * pts[0].x - pts[1].x, y: 2 * pts[0].y - pts[1].y)
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 <= n - 1 ? pts[i + 2] : Point(x: 2 * pts[n - 1].x - pts[n - 2].x, y: 2 * pts[n - 1].y - pts[n - 2].y)
            for s in 0..<subdivisions {
                let t = Double(s) / Double(subdivisions)
                out.append(segment(p0, p1, p2, p3, t))
            }
        }
        out.append(pts[n - 1])

        // Unproject back to lat/lon.
        return out.map { CLLocationCoordinate2D(latitude: $0.y, longitude: $0.x / lonScale) }
    }

    /// A point in the local planar frame (x = longitude·cos(lat), y = latitude).
    private struct Point { var x: Double; var y: Double }

    /// Remove consecutive points closer than ~0.15m (in the planar frame's degree units) so the
    /// centripetal knot spacing never divides by a zero-length span.
    private static func dedupe(_ pts: [Point]) -> [Point] {
        guard let first = pts.first else { return pts }
        // ~0.15m expressed in degrees (1° ≈ 111_320 m). Squared for a cheap comparison.
        let minDeltaDeg = 0.15 / 111_320.0
        let minDelta2 = minDeltaDeg * minDeltaDeg
        var out = [first]
        for p in pts.dropFirst() {
            let last = out[out.count - 1]
            let dx = p.x - last.x, dy = p.y - last.y
            if dx * dx + dy * dy >= minDelta2 { out.append(p) }
        }
        return out
    }

    /// One symmetric [1,2,1]/4 pass over the interior points — pulls each toward its neighbors to
    /// damp the lateral wobble of a single in-gate-but-imperfect fix (a point up to 25m off would
    /// otherwise bulge the line). Endpoints are held fixed so the trace still starts/ends where the
    /// athlete did, and the pass is gentle enough not to cut real corners. Display only — distance is
    /// accumulated upstream in `GPSProcessor` from the raw fixes and is untouched.
    private static func denoise(_ pts: [Point]) -> [Point] {
        guard pts.count >= 3 else { return pts }
        var out = pts
        for i in 1..<(pts.count - 1) {
            out[i] = Point(x: (pts[i - 1].x + 2 * pts[i].x + pts[i + 1].x) / 4,
                           y: (pts[i - 1].y + 2 * pts[i].y + pts[i + 1].y) / 4)
        }
        return out
    }

    /// Centripetal Catmull-Rom (α = 0.5) evaluated at `t ∈ [0,1)` across the span between `p1` and
    /// `p2`, via the numerically-stable Barry-Goldman pyramid. Knot spacing uses the square root of
    /// the chord length between control points, which is what removes the overshoot/looping that a
    /// uniform Catmull-Rom produces on sharp turns.
    private static func segment(_ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point, _ t: Double) -> Point {
        let t0 = 0.0
        let t1 = t0 + knot(p0, p1)
        let t2 = t1 + knot(p1, p2)
        let t3 = t2 + knot(p2, p3)
        // Map the local parameter onto the [t1, t2] knot interval this span covers.
        let tt = t1 + (t2 - t1) * t

        let a1 = lerp(p0, p1, (t1 - tt) / (t1 - t0), (tt - t0) / (t1 - t0))
        let a2 = lerp(p1, p2, (t2 - tt) / (t2 - t1), (tt - t1) / (t2 - t1))
        let a3 = lerp(p2, p3, (t3 - tt) / (t3 - t2), (tt - t2) / (t3 - t2))
        let b1 = lerp(a1, a2, (t2 - tt) / (t2 - t0), (tt - t0) / (t2 - t0))
        let b2 = lerp(a2, a3, (t3 - tt) / (t3 - t1), (tt - t1) / (t3 - t1))
        return lerp(b1, b2, (t2 - tt) / (t2 - t1), (tt - t1) / (t2 - t1))
    }

    /// Centripetal knot delta between two control points: `chordLength^0.5`, floored to a tiny
    /// epsilon so a degenerate span (should be gone after `dedupe`) can never divide by zero.
    private static func knot(_ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        return max(1e-9, pow(dx * dx + dy * dy, 0.25))   // (d²)^0.25 == d^0.5
    }

    /// Weighted blend `wa·a + wb·b` (the two weights sum to 1 for an affine combination).
    private static func lerp(_ a: Point, _ b: Point, _ wa: Double, _ wb: Double) -> Point {
        Point(x: wa * a.x + wb * b.x, y: wa * a.y + wb * b.y)
    }
}

// MARK: - Live incremental smoothing

extension RouteSmoothing {

    /// Incrementally-maintained live spline for the recording map. `smooth(_:)` is O(n) per call, so
    /// re-splining the whole route on every fix is O(n²) over a session — a 3-hour ride re-shapes
    /// ~10k points on the main thread every second by the end. The spline is *local* (each output
    /// span depends on ≤6 neighboring input points), so instead this freezes spans once their
    /// neighborhood can no longer change and re-computes only a short live tail per fix: O(1)
    /// amortized, and **bit-identical to `smooth(_:)`** on the same input (pinned by tests).
    ///
    /// It also splits the trace where the data actually gapped (tunnel, long reject stretch): a jump
    /// of `gapSplitM` between consecutive accepted points ends the current segment instead of
    /// drawing a chord through buildings. Chunks are emitted for append-only rendering
    /// (`addGeoJSONSourceFeatures`) so the per-fix payload to Mapbox stays O(tail) too.
    struct LiveSmoother {
        /// Straight-line jump between consecutive accepted route points that reads as a data gap,
        /// not movement (accepted points are normally ≤ a few fix-intervals apart).
        static let gapSplitM = 100.0
        /// Spans kept live at the tail. A span is final once its ±2-point denoise neighborhood is
        /// final; 5 is deliberately one more than the math needs.
        private static let tailSpans = 5

        private let subdivisions: Int

        // Current segment state (a segment = a gap-free stretch of the route).
        private var pts: [Point] = []            // deduped, planar
        private var rawSegment: [CLLocationCoordinate2D] = []  // pre-spline fallback while pts < 3
        private var lonScale = 1.0
        private var frozenSpans = 0

        // Whole-route state.
        private var consumed = 0                 // route points ingested so far
        private var lastRaw: CLLocationCoordinate2D?
        private(set) var allChunks: [[CLLocationCoordinate2D]] = []   // for style-reload rebuilds
        private(set) var tail: [CLLocationCoordinate2D] = []

        init(subdivisions: Int = 6) { self.subdivisions = subdivisions }

        /// What changed this ingest: chunks to append (final — never re-sent) and the tail to replace.
        struct Delta {
            var newChunks: [[CLLocationCoordinate2D]] = []
            var tail: [CLLocationCoordinate2D] = []
        }

        /// Feed the growing route (append-only — pass the whole array or any slice of it; only
        /// points past those already ingested are read, so a slice avoids copying the route per
        /// fix). Positions are counted from the COLLECTION'S OWN start: element 0 of every call
        /// must be the same route point, however the caller sliced it.
        mutating func ingest<R: RandomAccessCollection>(_ route: R) -> Delta
        where R.Element == CLLocationCoordinate2D {
            var delta = Delta()
            guard route.count > consumed else { delta.tail = tail; return delta }
            // startIndex-relative, never absolute: a slice's indices need not begin at 0 (an
            // `ArraySlice` from `coords[k...]` starts at k), so `route[consumed...]` would re-read
            // wrong elements — or trap — on anything but a zero-based collection.
            for coord in route[route.index(route.startIndex, offsetBy: consumed)...] {
                if let last = lastRaw,
                   Geo.distance(lat1: last.latitude, lon1: last.longitude,
                                lat2: coord.latitude, lon2: coord.longitude) > Self.gapSplitM {
                    // Real data gap: finalize this segment where it stands and start a new one —
                    // separate features never connect, so no chord is drawn across the gap.
                    if !tail.isEmpty { allChunks.append(tail); delta.newChunks.append(tail) }
                    pts = []; rawSegment = []; frozenSpans = 0; tail = []
                }
                lastRaw = coord
                appendToSegment(coord)
            }
            consumed = route.count

            // Freeze every span whose neighborhood is now final, emitting one chunk for the batch.
            let n = pts.count
            let target = max(frozenSpans, n - 1 - Self.tailSpans)
            if n >= 3, target > frozenSpans {
                var chunk: [CLLocationCoordinate2D] = []
                for span in frozenSpans..<target { emit(span: span, into: &chunk) }
                chunk.append(unproject(denoised(target)))   // shared closing point — keeps the line continuous
                frozenSpans = target
                allChunks.append(chunk)
                delta.newChunks.append(chunk)
            }

            tail = liveTail()
            delta.tail = tail
            return delta
        }

        // MARK: internals

        private mutating func appendToSegment(_ coord: CLLocationCoordinate2D) {
            rawSegment.append(coord)
            if pts.isEmpty { lonScale = cos(coord.latitude * .pi / 180) }
            let p = Point(x: coord.longitude * lonScale, y: coord.latitude)
            // Same sequential dedupe rule as `smooth(_:)`.
            if let last = pts.last {
                let minDeltaDeg = 0.15 / 111_320.0
                let dx = p.x - last.x, dy = p.y - last.y
                guard dx * dx + dy * dy >= minDeltaDeg * minDeltaDeg else { return }
            }
            pts.append(p)
        }

        /// The re-shaped live end of the segment: everything not yet frozen.
        private func liveTail() -> [CLLocationCoordinate2D] {
            let n = pts.count
            guard n >= 3 else { return rawSegment }   // matches smooth(_:)'s pass-through
            var out: [CLLocationCoordinate2D] = []
            for span in frozenSpans..<(n - 1) { emit(span: span, into: &out) }
            out.append(unproject(pts[n - 1]))         // endpoint held raw, same as smooth(_:)
            return out
        }

        /// Emit one span's `subdivisions` points (t ∈ [0,1)); identical math to `smooth(_:)`.
        private func emit(span i: Int, into out: inout [CLLocationCoordinate2D]) {
            let n = pts.count
            let d0 = denoised(max(i - 1, 0)), d1 = denoised(i)
            let p0 = i - 1 >= 0 ? d0 : Point(x: 2 * denoised(0).x - denoised(1).x,
                                             y: 2 * denoised(0).y - denoised(1).y)
            let p1 = d1
            let p2 = denoised(i + 1)
            let p3 = i + 2 <= n - 1 ? denoised(i + 2)
                                    : Point(x: 2 * denoised(n - 1).x - denoised(n - 2).x,
                                            y: 2 * denoised(n - 1).y - denoised(n - 2).y)
            for s in 0..<subdivisions {
                out.append(unproject(RouteSmoothing.segment(p0, p1, p2, p3, Double(s) / Double(subdivisions))))
            }
        }

        /// The [1,2,1]/4 denoise of point `j`, computed on demand from the raw deduped points —
        /// identical to `smooth(_:)`'s pre-pass (endpoints held fixed).
        private func denoised(_ j: Int) -> Point {
            let n = pts.count
            guard j > 0, j < n - 1 else { return pts[j] }
            return Point(x: (pts[j - 1].x + 2 * pts[j].x + pts[j + 1].x) / 4,
                         y: (pts[j - 1].y + 2 * pts[j].y + pts[j + 1].y) / 4)
        }

        private func unproject(_ p: Point) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: p.y, longitude: p.x / lonScale)
        }
    }
}
