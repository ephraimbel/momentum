import Testing
import CoreLocation
@testable import Momentum

/// Pins for the route milestone walker — the km/mi badges must land exactly one display unit
/// apart along the drawn line, whatever the vertex spacing.
struct RouteMilestonesTests {

    /// Routes built due north so ground distance is a pure function of latitude delta. The
    /// meters→degrees scale is derived from `Geo.distance` itself (not a hardcoded WGS84
    /// constant) so fixture distances are exact in the engine's own metric.
    private func northRoute(stepM: Double, steps: Int, startLat: Double = 0) -> [CLLocationCoordinate2D] {
        let degPerMeter = 1.0 / Geo.distance(lat1: 0, lon1: 0, lat2: 1, lon2: 0)
        return (0...steps).map {
            CLLocationCoordinate2D(latitude: startLat + Double($0) * stepM * degPerMeter, longitude: 0)
        }
    }

    @Test func dropsOneMarkerPerWholeUnit() {
        // 4500 m of route at 1 km units → markers 1–4, none for the partial tail.
        let coords = northRoute(stepM: 100, steps: 45)
        let marks = RouteMilestones.along(coords, unitMeters: 1000)
        #expect(marks.map(\.index) == [1, 2, 3, 4])
    }

    @Test func markersAreExactlyOneUnitApart() {
        // Vertices every 700 m deliberately misaligned with the 1 km unit — every boundary
        // falls mid-segment and must be interpolated.
        let coords = northRoute(stepM: 700, steps: 10)   // 7 km
        let marks = RouteMilestones.along(coords, unitMeters: 1000)
        #expect(marks.count == 7)
        for (i, m) in marks.enumerated() {
            let fromStart = Geo.distance(lat1: coords[0].latitude, lon1: 0,
                                         lat2: m.coordinate.latitude, lon2: 0)
            #expect(abs(fromStart - Double(i + 1) * 1000) < 1.0)
        }
    }

    @Test func routeShorterThanOneUnitHasNoMarkers() {
        let coords = northRoute(stepM: 100, steps: 8)   // 800 m
        #expect(RouteMilestones.along(coords, unitMeters: 1000).isEmpty)
        #expect(RouteMilestones.along(coords, unitMeters: 0).isEmpty)
        #expect(RouteMilestones.along([], unitMeters: 1000).isEmpty)
    }

    @Test func boundaryOnAVertexLandsOnThatVertex() {
        // Vertices every 500 m: km boundaries coincide with every second vertex.
        let coords = northRoute(stepM: 500, steps: 6)   // 3 km
        let marks = RouteMilestones.along(coords, unitMeters: 1000)
        // 1e-7° ≈ 1 cm — "on the vertex" to within float round-trip through the haversine.
        #expect(marks.count == 3)
        #expect(abs(marks[0].coordinate.latitude - coords[2].latitude) < 1e-7)
        #expect(abs(marks[2].coordinate.latitude - coords[6].latitude) < 1e-7)
    }

    @Test func mileUnitsPlaceMileMarkers() {
        let coords = northRoute(stepM: 200, steps: 40)   // 8 km ≈ 4.97 mi
        let marks = RouteMilestones.along(coords, unitMeters: Formatters.metersPerMile)
        #expect(marks.map(\.index) == [1, 2, 3, 4])
        let fromStart = Geo.distance(lat1: coords[0].latitude, lon1: 0,
                                     lat2: marks[0].coordinate.latitude, lon2: 0)
        #expect(abs(fromStart - Formatters.metersPerMile) < 1.0)
    }
}
