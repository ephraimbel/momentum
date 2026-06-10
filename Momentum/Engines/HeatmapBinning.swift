import Foundation

/// One aggregated grid cell of the personal heatmap: a place, how many of the athlete's own accepted
/// fixes landed there, and that count normalised against the busiest cell.
struct HeatCell: Sendable, Equatable {
    let lat: Double
    let lon: Double
    let count: Int
    let weight: Double   // count / busiest-count, 0…1 (linear; the renderer applies the visual curve)
}

/// Pure, testable density binning for the **personal** heatmap — the "private mirror" (north-star):
/// where *you* have been active, never a public ledger. Quantises the athlete's own accepted GPS
/// coordinates into a ~`cellMeters` grid and weights each cell by how often they've been there, so
/// frequented streets glow and a one-off route still registers. No rendering here — `HeatmapMapView`
/// draws the cells. Deterministic and CoreLocation-free so it unit-tests like the other engines.
enum HeatmapBinning {
    static let metersPerDegLat = 111_320.0

    /// Bin `coords` into a lat/lon grid of roughly `cellMeters` resolution.
    static func bin(_ coords: [GeoPoint], cellMeters: Double = 25) -> [HeatCell] {
        guard !coords.isEmpty, cellMeters > 0 else { return [] }
        // Longitude degrees shrink with latitude (cos); scale at the data's mean lat. The athlete's
        // routes are local, so a single reference latitude is accurate enough.
        let meanLat = coords.reduce(0) { $0 + $1.lat } / Double(coords.count)
        let latDeg = cellMeters / metersPerDegLat
        let lonDeg = cellMeters / (metersPerDegLat * max(0.01, cos(meanLat * .pi / 180)))

        var counts: [Cell: Int] = [:]
        for c in coords {
            let key = Cell(i: Int((c.lat / latDeg).rounded()), j: Int((c.lon / lonDeg).rounded()))
            counts[key, default: 0] += 1
        }
        let maxCount = Double(counts.values.max() ?? 1)
        return counts.map { key, count in
            HeatCell(lat: Double(key.i) * latDeg,
                     lon: Double(key.j) * lonDeg,
                     count: count,
                     weight: Double(count) / maxCount)
        }
    }

    private struct Cell: Hashable { let i: Int; let j: Int }
}
