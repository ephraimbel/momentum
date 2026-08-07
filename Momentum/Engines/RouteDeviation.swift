import Foundation

/// Pure geometry for the off-route nudge: how far is the athlete from the loop they chose to follow,
/// and which way is the nearest point back? Works in a local equirectangular projection — accurate at
/// route scale, CoreLocation-free, so it unit-tests like the other engines. No-shame coaching: the
/// *caller* decides the gentle cue; this just measures and points.
enum RouteDeviation {

    /// The closest point on the loop, and how far it is.
    struct Nearest: Sendable, Equatable {
        let point: GeoPoint
        let distanceM: Double
    }

    /// The nearest point on `polyline` to `point` (the minimum over its segments). Nil for an empty
    /// polyline; the single vertex for a one-point polyline.
    static func nearest(on polyline: [GeoPoint], to point: GeoPoint) -> Nearest? {
        guard let first = polyline.first else { return nil }
        guard polyline.count >= 2 else { return Nearest(point: first, distanceM: first.distance(to: point)) }
        // Project to local metres with `point` at the origin (lon scaled by cos at this latitude).
        let mLat = 111_320.0
        let mLon = 111_320.0 * cos(point.lat * .pi / 180)
        func xy(_ g: GeoPoint) -> (x: Double, y: Double) { ((g.lon - point.lon) * mLon, (g.lat - point.lat) * mLat) }

        var best = Double.infinity, bestX = 0.0, bestY = 0.0
        for i in 0..<(polyline.count - 1) {
            let s = originToSegment(xy(polyline[i]), xy(polyline[i + 1]))
            if s.dist < best { best = s.dist; bestX = s.x; bestY = s.y }
        }
        return Nearest(point: GeoPoint(lat: point.lat + bestY / mLat, lon: point.lon + bestX / mLon), distanceM: best)
    }

    /// Initial great-circle bearing from `a` to `b` — degrees clockwise from true north, 0…360.
    /// On a north-up map this is also the on-screen rotation for a "head this way" arrow.
    static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let lat1 = a.lat * .pi / 180, lat2 = b.lat * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The closest point on segment `a`–`b` to the origin (the projected query point), and its distance.
    private static func originToSegment(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> (x: Double, y: Double, dist: Double) {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return (a.x, a.y, (a.x * a.x + a.y * a.y).squareRoot()) }   // degenerate segment
        let t = max(0, min(1, -(a.x * abx + a.y * aby) / len2))
        let px = a.x + t * abx, py = a.y + t * aby
        return (px, py, (px * px + py * py).squareRoot())
    }
}
