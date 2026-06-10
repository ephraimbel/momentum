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

    @Test func pointOnTheLineIsZero() {
        let onLine = offset(base, north: 0, east: 50)
        #expect(RouteDeviation.distanceToPolyline(onLine, eastLeg) < 1)
    }

    @Test func perpendicularOffsetMeasuresTheGap() {
        let off = offset(base, north: 50, east: 50)               // 50m north of the mid-segment
        let d = RouteDeviation.distanceToPolyline(off, eastLeg)
        #expect(abs(d - 50) < 1.5, "expected ~50m, got \(d)")
    }

    @Test func beyondTheEndpointClampsToIt() {
        let past = offset(base, north: 0, east: 200)              // 100m past the segment's end
        let d = RouteDeviation.distanceToPolyline(past, eastLeg)
        #expect(abs(d - 100) < 1.5, "expected ~100m to the endpoint, got \(d)")
    }

    @Test func nearestOfMultipleSegmentsWins() {
        // An L: east 100m, then north 100m. A point near the elbow's north leg.
        let elbow = offset(base, north: 0, east: 100)
        let poly = [base, elbow, offset(elbow, north: 100, east: 0)]
        let p = offset(elbow, north: 50, east: 20)               // 20m east of the north leg
        #expect(abs(RouteDeviation.distanceToPolyline(p, poly) - 20) < 1.5)
    }

    @Test func emptyAndSinglePointDegenerate() {
        #expect(RouteDeviation.distanceToPolyline(base, []) == .infinity)
        let single = offset(base, north: 30, east: 0)
        #expect(abs(RouteDeviation.distanceToPolyline(single, [base]) - 30) < 1)
    }
}
