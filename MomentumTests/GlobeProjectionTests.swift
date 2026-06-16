import Testing
import Foundation
@testable import Momentum

/// Orthographic globe projection (docs/SOCIAL-LAYER.md, Slice 3).
struct GlobeProjectionTests {

    @Test func frontPointFacesViewer() {
        let p = GlobeProjection(rotation: 0, tilt: 0).project(latDeg: 0, lonDeg: 0)
        #expect(p.front)
        #expect(abs(p.x) < 1e-9 && abs(p.y) < 1e-9)   // dead center
        #expect(abs(p.depth - 1) < 1e-9)               // closest to viewer
    }

    @Test func backPointIsCulled() {
        let p = GlobeProjection(rotation: 0, tilt: 0).project(latDeg: 0, lonDeg: 180)
        #expect(!p.front)                              // far side hidden
        #expect(p.depth < 0)
    }

    @Test func rotationBringsMeridianToFront() {
        // The 180° meridian is hidden at rotation 0, visible after spinning half a turn.
        let hidden = GlobeProjection(rotation: 0, tilt: 0).project(latDeg: 0, lonDeg: 180)
        let shown = GlobeProjection(rotation: .pi, tilt: 0).project(latDeg: 0, lonDeg: 180)
        #expect(!hidden.front)
        #expect(shown.front)
    }

    @Test func eastLongitudeProjectsRight() {
        let p = GlobeProjection(rotation: 0, tilt: 0).project(latDeg: 0, lonDeg: 90)
        #expect(p.x > 0.9)                             // +90° lon → right edge
    }

    @Test func northPoleProjectsUpWithTilt() {
        // With a downward tilt the north pole lifts into view above center.
        let p = GlobeProjection(rotation: 0, tilt: 0.35).project(latDeg: 90, lonDeg: 0)
        #expect(p.y > 0.5)
    }

    @Test func screenMapsUnitToPixels() {
        let p = GlobeProjection.Point(x: 1, y: 1, depth: 0.5)
        let s = GlobeProjection.screen(p, center: CGPoint(x: 100, y: 100), radius: 50)
        #expect(s.x == 150)
        #expect(s.y == 50)                             // y is flipped (screen down = -y)
    }
}
