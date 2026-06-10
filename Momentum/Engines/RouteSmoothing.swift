import Foundation
import CoreLocation

/// Catmull-Rom spline smoothing for GPS route polylines (PRD §8.5 — the Strava-smooth trace).
///
/// Accepted fixes are deliberately **sparse** — `GPSProcessor` only appends a route point once
/// movement clears the 2m gate (`minMovementGateM`) — so the raw polyline renders as hard angles at
/// every turn. Passing the points through a Catmull-Rom spline rounds those corners into the fluid,
/// hand-drawn-looking track users expect, with no effect on distance: distance is accumulated
/// upstream in `GPSProcessor` from the raw fixes, never measured off this rendered line.
///
/// Pure and `CLLocation`-free of UIKit — used by the live map, the history map, and the saved
/// snapshot so all three read identically.
enum RouteSmoothing {

    /// Interpolate a Catmull-Rom spline through `coords`. Returns the input unchanged for fewer than
    /// three points (a spline needs a neighbor on each side). Over short, local spans the latitude/
    /// longitude can be treated as a planar coordinate pair without meaningful distortion.
    /// - Parameter subdivisions: interpolated segments inserted per input span; higher = smoother
    ///   and denser. 6 reads fluid at running point density without bloating the polyline.
    static func smooth(_ coords: [CLLocationCoordinate2D], subdivisions: Int = 6) -> [CLLocationCoordinate2D] {
        guard coords.count >= 3, subdivisions >= 1 else { return coords }
        // Denoise first so the spline rounds a clean path instead of faithfully tracing through
        // within-gate GPS wobble, then interpolate.
        let pts = denoise(coords)
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity((pts.count - 1) * subdivisions + 1)
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(pts.count - 1, i + 2)]
            for s in 0..<subdivisions {
                let t = Double(s) / Double(subdivisions)
                out.append(point(p0, p1, p2, p3, t))
            }
        }
        out.append(pts[pts.count - 1])
        return out
    }

    /// One symmetric [1,2,1]/4 pass over the interior points — pulls each toward its neighbors to
    /// damp the lateral wobble of a single in-gate-but-imperfect fix (a point up to 25m off would
    /// otherwise bulge the line). Endpoints are held fixed so the trace still starts/ends where the
    /// athlete did, and the pass is gentle enough not to cut real corners. Display only — distance is
    /// accumulated upstream in `GPSProcessor` from the raw fixes and is untouched.
    private static func denoise(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coords.count >= 3 else { return coords }
        var out = coords
        for i in 1..<(coords.count - 1) {
            out[i] = CLLocationCoordinate2D(
                latitude: (coords[i - 1].latitude + 2 * coords[i].latitude + coords[i + 1].latitude) / 4,
                longitude: (coords[i - 1].longitude + 2 * coords[i].longitude + coords[i + 1].longitude) / 4)
        }
        return out
    }

    /// The Catmull-Rom basis evaluated at `t ∈ [0,1)` for the span between `p1` and `p2`.
    private static func point(_ p0: CLLocationCoordinate2D, _ p1: CLLocationCoordinate2D,
                              _ p2: CLLocationCoordinate2D, _ p3: CLLocationCoordinate2D,
                              _ t: Double) -> CLLocationCoordinate2D {
        let t2 = t * t, t3 = t2 * t
        let lat = 0.5 * (2 * p1.latitude
            + (-p0.latitude + p2.latitude) * t
            + (2 * p0.latitude - 5 * p1.latitude + 4 * p2.latitude - p3.latitude) * t2
            + (-p0.latitude + 3 * p1.latitude - 3 * p2.latitude + p3.latitude) * t3)
        let lon = 0.5 * (2 * p1.longitude
            + (-p0.longitude + p2.longitude) * t
            + (2 * p0.longitude - 5 * p1.longitude + 4 * p2.longitude - p3.longitude) * t2
            + (-p0.longitude + 3 * p1.longitude - 3 * p2.longitude + p3.longitude) * t3)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
