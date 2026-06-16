import Foundation

/// Pure orthographic projection of lat/lon onto a spinning globe (docs/SOCIAL-LAYER.md, Slice 3).
/// Extracted from the view so the math is unit-testable. Returns a unit-sphere offset in [-1, 1] plus
/// a `front` flag (visible hemisphere) and `depth` (z, for size/brightness falloff).
struct GlobeProjection: Equatable {
    /// Longitude spin in radians (auto-rotate + drag).
    var rotation: Double = 0
    /// Tilt about the screen-x axis in radians (drag up/down); slight default tilt shows the north.
    var tilt: Double = 0.35

    struct Point: Equatable { let x: Double; let y: Double; let depth: Double; var front: Bool { depth > 0 } }

    func project(latDeg: Double, lonDeg: Double) -> Point {
        let lat = latDeg * .pi / 180
        let lon = lonDeg * .pi / 180 + rotation
        let cosLat = cos(lat)
        let x = cosLat * sin(lon)
        let y0 = sin(lat)
        let z0 = cosLat * cos(lon)
        // Tilt about the x-axis (x unchanged).
        let y = y0 * cos(tilt) - z0 * sin(tilt)
        let z = y0 * sin(tilt) + z0 * cos(tilt)
        return Point(x: x, y: y, depth: z)
    }

    /// Convert a projected unit point to a screen position within a square globe of the given radius.
    static func screen(_ p: Point, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * p.x, y: center.y - radius * p.y)
    }
}
