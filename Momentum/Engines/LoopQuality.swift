import Foundation

/// Pure geometry quality metrics for a suggested running loop (PRD §6) — lets the engine prefer
/// **round, real loops** over lopsided out-and-backs. No routing or network, so it's fully testable.
/// Coordinates are projected to local metres (equirectangular about the loop's centroid; accurate at
/// loop scale, a few km).
enum LoopQuality {

    /// Isoperimetric quotient `4πA / P²` ∈ [0, 1]: **1 for a circle, → 0 for a thin out-and-back**.
    /// The single best "is this a real loop?" signal — a there-and-back encloses ~no area.
    static func roundness(_ poly: [GeoPoint]) -> Double {
        guard poly.count >= 3 else { return 0 }
        let pts = projected(poly)
        let perim = perimeter(pts)
        guard perim > 0 else { return 0 }
        let area = abs(signedArea(pts))
        return min(1, 4 * Double.pi * area / (perim * perim))
    }

    /// Length-weighted fraction of the path that doubles back on itself — consecutive segments pointing
    /// ~opposite ways (turn sharper than 150°). High on out-and-backs, ~0 on a clean loop.
    static func backtrackFraction(_ poly: [GeoPoint]) -> Double {
        let pts = projected(poly)
        guard pts.count >= 3 else { return 0 }
        var back = 0.0, total = 0.0
        for i in 1..<(pts.count - 1) {
            let a = sub(pts[i], pts[i - 1]), b = sub(pts[i + 1], pts[i])
            let la = mag(a), lb = mag(b)
            total += lb
            guard la > 0, lb > 0 else { continue }
            if dot(a, b) / (la * lb) < cos150 { back += lb }   // heading reversed
        }
        return total > 0 ? back / total : 0
    }

    /// The loop's centroid (mean of its points) — used to tell whether two loops are the same place.
    static func centroid(_ poly: [GeoPoint]) -> GeoPoint {
        guard !poly.isEmpty else { return GeoPoint(lat: 0, lon: 0) }
        let n = Double(poly.count)
        return GeoPoint(lat: poly.reduce(0) { $0 + $1.lat } / n,
                        lon: poly.reduce(0) { $0 + $1.lon } / n)
    }

    // MARK: math

    private static let cos150 = cos(150 * Double.pi / 180)
    private struct P { let x, y: Double }

    private static func projected(_ poly: [GeoPoint]) -> [P] {
        let n = Double(poly.count)
        let lat0 = poly.reduce(0) { $0 + $1.lat } / n
        let lon0 = poly.reduce(0) { $0 + $1.lon } / n
        let mPerDegLat = 111_132.0
        let mPerDegLon = 111_320.0 * cos(lat0 * Double.pi / 180)
        return poly.map { P(x: ($0.lon - lon0) * mPerDegLon, y: ($0.lat - lat0) * mPerDegLat) }
    }

    private static func signedArea(_ p: [P]) -> Double {
        guard p.count > 2 else { return 0 }
        var a = 0.0
        for i in 0..<p.count { let j = (i + 1) % p.count; a += p[i].x * p[j].y - p[j].x * p[i].y }
        return a / 2
    }

    private static func perimeter(_ p: [P]) -> Double {
        guard p.count > 1 else { return 0 }
        var s = 0.0
        for i in 0..<p.count { let j = (i + 1) % p.count; s += mag(sub(p[j], p[i])) }
        return s
    }

    private static func sub(_ a: P, _ b: P) -> P { P(x: a.x - b.x, y: a.y - b.y) }
    private static func dot(_ a: P, _ b: P) -> Double { a.x * b.x + a.y * b.y }
    private static func mag(_ a: P) -> Double { (a.x * a.x + a.y * a.y).squareRoot() }
}
