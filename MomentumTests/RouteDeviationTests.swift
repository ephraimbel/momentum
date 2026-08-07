import Testing
import Foundation
@testable import Momentum

/// `RouteDeviation` — the point-to-polyline distance behind the off-route nudge.
struct RouteDeviationTests {
    let base = GeoPoint(lat: 37.7686, lon: -122.4830)

    func offset(_ p: GeoPoint, north n: Double, east e: Double) -> GeoPoint {
        GeoPoint(lat: p.lat + n / 111_320, lon: p.lon + e / (111_320 * cos(p.lat * .pi / 180)))
    }

    /// A 100m segment running due east from `base`.
    private var eastLeg: [GeoPoint] { [base, offset(base, north: 0, east: 100)] }

    /// The tests exercise `nearest` (the live route-guidance math) directly — the old
    /// `distanceToPolyline` convenience wrapper was deleted on the 2026-08-06 dead-code pass.
    private func distance(_ p: GeoPoint, _ poly: [GeoPoint]) -> Double {
        RouteDeviation.nearest(on: poly, to: p)?.distanceM ?? .infinity
    }

    @Test func pointOnTheLineIsZero() {
        let onLine = offset(base, north: 0, east: 50)
        #expect(distance(onLine, eastLeg) < 1)
    }

    @Test func perpendicularOffsetMeasuresTheGap() {
        let off = offset(base, north: 50, east: 50)               // 50m north of the mid-segment
        let d = distance(off, eastLeg)
        #expect(abs(d - 50) < 1.5, "expected ~50m, got \(d)")
    }

    @Test func beyondTheEndpointClampsToIt() {
        let past = offset(base, north: 0, east: 200)              // 100m past the segment's end
        let d = distance(past, eastLeg)
        #expect(abs(d - 100) < 1.5, "expected ~100m to the endpoint, got \(d)")
    }

    @Test func nearestOfMultipleSegmentsWins() {
        // An L: east 100m, then north 100m. A point near the elbow's north leg.
        let elbow = offset(base, north: 0, east: 100)
        let poly = [base, elbow, offset(elbow, north: 100, east: 0)]
        let p = offset(elbow, north: 50, east: 20)               // 20m east of the north leg
        #expect(abs(distance(p, poly) - 20) < 1.5)
    }

    @Test func emptyAndSinglePointDegenerate() {
        #expect(distance(base, []) == .infinity)
        let single = offset(base, north: 30, east: 0)
        #expect(abs(distance(single, [base]) - 30) < 1)
        #expect(RouteDeviation.nearest(on: [], to: base) == nil)
    }

    @Test func nearestPointSitsOnTheLoop() throws {
        let off = offset(base, north: 50, east: 50)
        let n = try #require(RouteDeviation.nearest(on: eastLeg, to: off))
        #expect(abs(n.distanceM - 50) < 1.5)
        // The foot of the perpendicular is on the segment (~base latitude, ~50m east).
        #expect(abs(n.point.lat - base.lat) < 1e-5)
        #expect(n.point.distance(to: offset(base, north: 0, east: 50)) < 2)
    }

    @Test func bearingPointsTheRightWay() {
        // Due north ⇒ ~0°, due east ⇒ ~90°, due west ⇒ ~270°.
        #expect(angularGap(RouteDeviation.bearing(from: base, to: offset(base, north: 100, east: 0)), 0) < 1)
        #expect(angularGap(RouteDeviation.bearing(from: base, to: offset(base, north: 0, east: 100)), 90) < 1)
        #expect(angularGap(RouteDeviation.bearing(from: base, to: offset(base, north: 0, east: -100)), 270) < 1)
    }

    /// Smallest absolute difference between two compass bearings (handles the 0/360 wrap).
    private func angularGap(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}
