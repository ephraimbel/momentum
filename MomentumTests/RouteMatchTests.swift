import Testing
import Foundation
@testable import Momentum

/// `RouteMatch` decides whether the athlete has run this exact route before, and the whole verdict
/// ladder above it inherits that answer. A false positive tells someone they were slower on a route
/// they have never set foot on; a false negative silently drops them back to distance comparison.
/// Both are pinned here.
struct RouteMatchTests {

    // MARK: Fixtures

    /// Downtown Austin, where the seeded demo runs live. Far enough from the equator that the
    /// longitude cosine actually matters, which is the point of the reference-latitude invariant.
    private static let originLat = 30.2672
    private static let originLon = -97.7431

    private static let metersPerDegLat = 111_320.0
    private static var metersPerDegLon: Double { metersPerDegLat * cos(originLat * .pi / 180) }

    /// A point `north`/`east` metres from the origin.
    private func at(north: Double, east: Double) -> GeoPoint {
        GeoPoint(lat: Self.originLat + north / Self.metersPerDegLat,
                 lon: Self.originLon + east / Self.metersPerDegLon)
    }

    /// A rectangular loop of `side` metres, sampled every ~5 m the way real fixes arrive.
    private func loop(side: Double, offsetNorth: Double = 0, offsetEast: Double = 0,
                      step: Double = 5) -> [GeoPoint] {
        var pts: [GeoPoint] = []
        var d = 0.0
        while d < side { pts.append(at(north: offsetNorth, east: offsetEast + d)); d += step }
        d = 0
        while d < side { pts.append(at(north: offsetNorth + d, east: offsetEast + side)); d += step }
        d = 0
        while d < side { pts.append(at(north: offsetNorth + side, east: offsetEast + side - d)); d += step }
        d = 0
        while d < side { pts.append(at(north: offsetNorth + side - d, east: offsetEast)); d += step }
        pts.append(at(north: offsetNorth, east: offsetEast))   // close it
        return pts
    }

    /// A straight out-and-back of `length` metres each way.
    private func outAndBack(length: Double, step: Double = 5) -> [GeoPoint] {
        var pts: [GeoPoint] = []
        var d = 0.0
        while d < length { pts.append(at(north: 0, east: d)); d += step }
        while d > 0 { pts.append(at(north: 0, east: d)); d -= step }
        pts.append(at(north: 0, east: 0))
        return pts
    }

    private func signature(_ pts: [GeoPoint], distanceM: Double, ref: Double? = nil) -> RouteMatch.Signature {
        RouteMatch.signature(coords: pts, distanceM: distanceM,
                             referenceLat: ref ?? RouteMatch.referenceLat(pts))
    }

    // MARK: The same route

    @Test func aRouteMatchesItself() {
        let pts = loop(side: 800)
        let ref = RouteMatch.referenceLat(pts)
        let a = signature(pts, distanceM: 3_200, ref: ref)
        #expect(RouteMatch.matches(a, a))
    }

    @Test func theSameLoopRunTheOtherWayIsTheSameRoute() {
        // Footprints are direction-agnostic on purpose: a runner reversing their loop would be
        // surprised to be told it was somewhere new.
        let pts = loop(side: 800)
        let ref = RouteMatch.referenceLat(pts)
        let clockwise = signature(pts, distanceM: 3_200, ref: ref)
        let anticlockwise = signature(pts.reversed(), distanceM: 3_190, ref: ref)
        #expect(RouteMatch.matches(clockwise, anticlockwise))
    }

    @Test func gpsJitterDoesNotBreakAMatch() {
        // Two runs down one street land their fixes metres apart, straddling cell boundaries. The
        // dilated containment test exists for exactly this.
        let pts = loop(side: 800)
        let ref = RouteMatch.referenceLat(pts)
        let today = signature(pts, distanceM: 3_200, ref: ref)
        let jittered = pts.enumerated().map { i, p in
            GeoPoint(lat: p.lat + (i.isMultiple(of: 2) ? 12 : -12) / Self.metersPerDegLat,
                     lon: p.lon + (i.isMultiple(of: 3) ? 10 : -10) / Self.metersPerDegLon)
        }
        #expect(RouteMatch.matches(today, signature(jittered, distanceM: 3_240, ref: ref)))
    }

    @Test func aSlightlyDifferentLineOnTheSameLoopStillMatches() {
        // Crossed at the other end of the block: a quarter of the loop shifted 30 m.
        let base = loop(side: 800)
        let ref = RouteMatch.referenceLat(base)
        let variant = base.map { p in
            p.lon > Self.originLon + 400 / Self.metersPerDegLon
                ? GeoPoint(lat: p.lat + 30 / Self.metersPerDegLat, lon: p.lon)
                : p
        }
        #expect(RouteMatch.matches(signature(base, distanceM: 3_200, ref: ref),
                                   signature(variant, distanceM: 3_260, ref: ref)))
    }

    // MARK: Different routes

    @Test func aDifferentLoopInTheSameNeighbourhoodDoesNotMatch() {
        // Same size, same city, 400 m away: the whole failure mode this engine exists to avoid.
        let mine = loop(side: 800)
        let ref = RouteMatch.referenceLat(mine)
        let theirs = loop(side: 800, offsetNorth: 400, offsetEast: 400)
        #expect(!RouteMatch.matches(signature(mine, distanceM: 3_200, ref: ref),
                                    signature(theirs, distanceM: 3_200, ref: ref)))
    }

    @Test func anOutAndBackDoesNotMatchTheOneWayVersionOfItself() {
        // Identical streets, identical footprint, twice the work. Only the distance gate can tell
        // these apart, which is why it is not optional.
        let there = outAndBack(length: 1_600)
        let ref = RouteMatch.referenceLat(there)
        var oneWay: [GeoPoint] = []
        var d = 0.0
        while d < 1_600 { oneWay.append(at(north: 0, east: d)); d += 5 }
        #expect(!RouteMatch.matches(signature(there, distanceM: 3_200, ref: ref),
                                    signature(oneWay, distanceM: 1_600, ref: ref)))
    }

    @Test func aLongerRunContainingAShorterOneIsNotTheSameRoute() {
        // Mutual containment, not one-sided: the short loop sits entirely inside the long one, and
        // the long one is emphatically not inside the short one.
        let short = loop(side: 400)
        let ref = RouteMatch.referenceLat(short)
        let long = loop(side: 400) + loop(side: 400, offsetNorth: 500)
        #expect(RouteMatch.coverage(of: signature(short, distanceM: 1_600, ref: ref).cells,
                                    within: RouteMatch.dilated(signature(long, distanceM: 3_200, ref: ref).cells)) > 0.9)
        #expect(!RouteMatch.matches(signature(short, distanceM: 1_600, ref: ref),
                                    signature(long, distanceM: 3_200, ref: ref)))
    }

    // MARK: Guards

    @Test func aFootprintTooSmallToIdentifyAnythingIsUnusable() {
        let stroll = [at(north: 0, east: 0), at(north: 0, east: 50), at(north: 0, east: 100)]
        let sig = signature(stroll, distanceM: 100)
        #expect(!sig.isUsable)
        #expect(!RouteMatch.matches(sig, sig))   // never matches, not even itself
    }

    @Test func aRunLongEnoughButWithTooFewCellsIsUnusable() {
        // A treadmill run recorded with a handful of stationary fixes: real distance, no route.
        let parked = Array(repeating: at(north: 0, east: 0), count: 500)
        #expect(!signature(parked, distanceM: 8_000).isUsable)
    }

    @Test func anEmptyTraceIsNeverContainedInAnything() {
        #expect(RouteMatch.coverage(of: [], within: RouteMatch.dilated(signature(loop(side: 800), distanceM: 3_200).cells)) == 0)
    }

    // MARK: The reference-latitude invariant

    @Test func referenceLatitudeIsTheMeanOfTheTrace() {
        let pts = [GeoPoint(lat: 30.0, lon: -97.0), GeoPoint(lat: 31.0, lon: -97.0)]
        #expect(abs(RouteMatch.referenceLat(pts) - 30.5) < 1e-9)
        #expect(RouteMatch.referenceLat([]) == 0)
    }

    @Test func distanceToleranceGateMatchesTheFullTest() {
        #expect(RouteMatch.withinDistanceTolerance(5_000, 5_000))
        #expect(RouteMatch.withinDistanceTolerance(5_000, 4_200))     // 16% under
        #expect(!RouteMatch.withinDistanceTolerance(5_000, 3_900))    // 22% under
        #expect(!RouteMatch.withinDistanceTolerance(0, 0))            // nothing to compare
    }

    @Test func dilationGrowsACellIntoItsNeighbourhood() {
        #expect(RouteMatch.dilated([RouteMatch.Cell(i: 0, j: 0)]).count == 9)
        // Adjacent cells share neighbours rather than each claiming nine.
        #expect(RouteMatch.dilated([RouteMatch.Cell(i: 0, j: 0), RouteMatch.Cell(i: 0, j: 1)]).count == 12)
    }

    // MARK: Loop detection (the noun the verdict uses)

    @Test func aClosedRouteReadsAsALoopAndAPointToPointDoesNot() {
        #expect(signature(loop(side: 800), distanceM: 3_200).isLoop)
        var oneWay: [GeoPoint] = []
        var d = 0.0
        while d < 3_000 { oneWay.append(at(north: 0, east: d)); d += 5 }
        #expect(!signature(oneWay, distanceM: 3_000).isLoop)
    }
}
