import Foundation

/// Pure geometry for the off-route nudge: how far is the athlete from the loop they chose to follow?
/// Computes the shortest distance from a point to a polyline (the minimum over its segments), in
/// metres, via a local equirectangular projection — accurate at route scale and CoreLocation-free, so
/// it unit-tests like the other engines. No-shame coaching: the *caller* decides the gentle cue; this
/// just measures.
enum RouteDeviation {

    /// Metres from `point` to the nearest point on `polyline`. `.infinity` for an empty polyline; the
    /// straight distance for a single point.
    static func distanceToPolyline(_ point: GeoPoint, _ polyline: [GeoPoint]) -> Double {
        guard polyline.count >= 2 else { return polyline.first?.distance(to: point) ?? .infinity }
        // Project to local metres with `point` at the origin (lon scaled by cos at this latitude).
        let mLat = 111_320.0
        let mLon = 111_320.0 * cos(point.lat * .pi / 180)
        func xy(_ g: GeoPoint) -> (x: Double, y: Double) { ((g.lon - point.lon) * mLon, (g.lat - point.lat) * mLat) }

        var best = Double.infinity
        for i in 0..<(polyline.count - 1) {
            best = min(best, originToSegment(xy(polyline[i]), xy(polyline[i + 1])))
        }
        return best
    }

    /// Distance from the origin (the projected query point) to segment `a`–`b`.
    private static func originToSegment(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return (a.x * a.x + a.y * a.y).squareRoot() }   // degenerate segment
        // Projection parameter of the origin onto the line, clamped to the segment.
        let t = max(0, min(1, -(a.x * abx + a.y * aby) / len2))
        let px = a.x + t * abx, py = a.y + t * aby
        return (px * px + py * py).squareRoot()
    }
}
