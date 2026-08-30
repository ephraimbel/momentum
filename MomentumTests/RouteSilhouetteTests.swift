import Testing
import Foundation
import CoreLocation
@testable import Momentum

/// The route drawn on share cards and post media. Owner report 2026-08-29: a track session — many
/// laps of one oval — rendered as a solid blob with the inside of the track coloured in. Nothing
/// filled the path (every call site strokes it); the every-Nth-point stride destroyed the shape.
struct RouteSilhouetteTests {

    /// `laps` times around a 400 m-ish oval, `perLap` fixes each, with a little GPS wobble so the
    /// laps are not byte-identical — exactly what a track session produces.
    private func track(laps: Int, perLap: Int) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for lap in 0..<laps {
            for i in 0..<perLap {
                let t = Double(i) / Double(perLap) * 2 * .pi
                let wobble = Double((lap * 7 + i) % 5) * 0.0000012
                out.append(.init(latitude: 30.2672 + 0.00090 * sin(t) + wobble,
                                 longitude: -97.7431 + 0.00180 * cos(t) + wobble))
            }
        }
        return out
    }

    @Test func everyLapSurvivesTheBudget() {
        // 20 laps × 120 fixes = 2,400 points. The stride kept 120 — six per lap, landing at a
        // different phase each time, which is what drew as a scribble. RDP keeps the bends.
        let coords = track(laps: 20, perLap: 120)
        let out = RouteSilhouette.downsample(coords, to: 800)
        #expect(out.count <= 800)
        // A lap needs several points to read as an oval rather than a polygon edge.
        #expect(out.count >= 20 * 8, "only \(out.count) points for 20 laps — laps are being erased")
    }

    @Test func theShapeIsPreservedNotJustThePointCount() {
        // The simplified route must still span the same ground: a downsample that clipped a lap
        // would shrink the bounding box.
        let coords = track(laps: 12, perLap: 100)
        let out = RouteSilhouette.downsample(coords, to: 800)
        func span(_ c: [CLLocationCoordinate2D]) -> (Double, Double) {
            (c.map(\.latitude).max()! - c.map(\.latitude).min()!,
             c.map(\.longitude).max()! - c.map(\.longitude).min()!)
        }
        let (fullLat, fullLon) = span(coords), (cutLat, cutLon) = span(out)
        #expect(cutLat > fullLat * 0.98)
        #expect(cutLon > fullLon * 0.98)
    }

    @Test func endpointsAreNeverDropped() {
        let coords = track(laps: 6, perLap: 80)
        let out = RouteSilhouette.downsample(coords, to: 120)
        #expect(out.first == coords.first)
        #expect(out.last == coords.last)
        #expect(out.count <= 120)
    }

    @Test func aStraightLineCollapsesAndShortRoutesAreUntouched() {
        // RDP's whole point: a straight road needs two points, not 500.
        let straight = (0..<500).map {
            CLLocationCoordinate2D(latitude: 30.0 + Double($0) * 0.0001, longitude: -97.0)
        }
        #expect(RouteSilhouette.downsample(straight, to: 120).count < 10)
        // Under budget: returned as-is, no resampling.
        let short = track(laps: 1, perLap: 40)
        #expect(RouteSilhouette.downsample(short, to: 120) == short)
    }

    @Test func rdpSurvivesADegenerateClosedSegment() {
        // A lap returns to its start, so RDP hits segments whose endpoints coincide — the
        // perpendicular-distance denominator is zero there and must not produce NaN.
        var coords = track(laps: 3, perLap: 60)
        coords.append(coords[0])
        let out = RouteSilhouette.downsample(coords, to: 100)
        #expect(!out.isEmpty)
        #expect(out.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite })
    }
}
