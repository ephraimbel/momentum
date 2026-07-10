import Testing
import Foundation
import CoreLocation
@testable import Momentum

/// `RouteSmoothing` — the centripetal Catmull-Rom spline behind the Strava-smooth trace (PRD §8.5).
/// These pin the two properties that make the curve read as "perfect": it densifies into a fluid
/// line, and it never overshoots into cusps or self-intersecting loops.
struct RouteSmoothingTests {
    let base = CLLocationCoordinate2D(latitude: 37.7686, longitude: -122.4830)

    /// Offset `base` by metres, using the same lat/lon-per-metre conversion the app uses.
    func offset(_ c: CLLocationCoordinate2D, north n: Double, east e: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude + n / 111_320,
                               longitude: c.longitude + e / (111_320 * cos(c.latitude * .pi / 180)))
    }

    func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        Geo.distance(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
    }

    /// An L-shaped path: 50m east, then 50m north — a sharp 90° corner is the classic case where a
    /// uniform Catmull-Rom overshoots.
    private var elbow: [CLLocationCoordinate2D] {
        let corner = offset(base, north: 0, east: 50)
        return [base, corner, offset(corner, north: 50, east: 0)]
    }

    @Test func passthroughForFewerThanThreePoints() {
        let two = [base, offset(base, north: 0, east: 10)]
        #expect(RouteSmoothing.smooth(two).count == two.count)
    }

    @Test func densifiesThePolyline() {
        let smoothed = RouteSmoothing.smooth(elbow, subdivisions: 6)
        // Two spans × 6 subdivisions + the closing point.
        #expect(smoothed.count == 2 * 6 + 1)
    }

    @Test func keepsTheEndpoints() {
        let smoothed = RouteSmoothing.smooth(elbow)
        #expect(meters(smoothed.first!, elbow.first!) < 0.5)
        #expect(meters(smoothed.last!, elbow.last!) < 0.5)
    }

    /// Centripetal parameterization must not overshoot: every smoothed point stays within the
    /// bounding box of the input (grown by a small tolerance). A uniform spline would bulge past the
    /// corner and fail this.
    @Test func doesNotOvershootOnASharpCorner() {
        let smoothed = RouteSmoothing.smooth(elbow)
        let lats = elbow.map(\.latitude), lons = elbow.map(\.longitude)
        let tol = 6.0 / 111_320   // ~6m of slack for the rounded corner
        for p in smoothed {
            #expect(p.latitude >= lats.min()! - tol && p.latitude <= lats.max()! + tol)
            #expect(p.longitude >= lons.min()! - tol && p.longitude <= lons.max()! + tol)
        }
    }

    /// No self-intersecting loops: along a monotonic path the smoothed line must keep advancing —
    /// consecutive points never reverse by more than a hair. This is the "glitch" a uniform spline
    /// introduces as little knots at sharp turns.
    @Test func staysMonotonicAlongAStraightRun() {
        // 200m due east in 20m steps.
        let straight = (0...10).map { offset(base, north: 0, east: Double($0) * 20) }
        let smoothed = RouteSmoothing.smooth(straight)
        for i in 1..<smoothed.count {
            // Longitude only ever increases (east) — never doubles back into a loop.
            #expect(smoothed[i].longitude >= smoothed[i - 1].longitude - 1e-9)
        }
    }

    /// Smoothing is display-only and must not meaningfully change path length: the rendered spline
    /// length stays within a few percent of the raw polyline, so it never implies a different route.
    @Test func preservesPathLengthWithinTolerance() {
        let path = (0...8).map { i -> CLLocationCoordinate2D in
            offset(base, north: sin(Double(i)) * 30, east: Double(i) * 25)
        }
        func length(_ pts: [CLLocationCoordinate2D]) -> Double {
            zip(pts, pts.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
        }
        let raw = length(path)
        let smoothed = length(RouteSmoothing.smooth(path))
        #expect(abs(smoothed - raw) / raw < 0.1)   // within 10%
    }
}
