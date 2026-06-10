import Testing
import Foundation
@testable import Momentum

/// `HeatmapBinning` — the pure density core behind the personal heatmap. No rendering, no network.
struct HeatmapBinningTests {
    let base = GeoPoint(lat: 37.7686, lon: -122.4830)

    func offset(_ p: GeoPoint, metresNorth n: Double, metresEast e: Double) -> GeoPoint {
        let mPerDegLat = HeatmapBinning.metersPerDegLat
        return GeoPoint(lat: p.lat + n / mPerDegLat,
                        lon: p.lon + e / (mPerDegLat * cos(p.lat * .pi / 180)))
    }

    @Test func emptyInputYieldsNoCells() {
        #expect(HeatmapBinning.bin([]).isEmpty)
    }

    @Test func coincidentPointsCollapseToOneCell() {
        let cells = HeatmapBinning.bin([base, base, base], cellMeters: 25)
        #expect(cells.count == 1)
        #expect(cells.first?.count == 3)
        #expect(cells.first?.weight == 1.0)            // the only/busiest cell is full weight
    }

    @Test func distantPointsSplitIntoSeparateCells() {
        let far = offset(base, metresNorth: 300, metresEast: 0)   // ≫ 25m cell
        let cells = HeatmapBinning.bin([base, far], cellMeters: 25)
        #expect(cells.count == 2)
        #expect(cells.allSatisfy { $0.count == 1 && $0.weight == 1.0 })
    }

    @Test func subCellJitterStaysInOneCell() {
        // Two fixes 5m apart land in the same ~25m cell.
        let nearby = offset(base, metresNorth: 5, metresEast: 0)
        #expect(HeatmapBinning.bin([base, nearby], cellMeters: 25).count == 1)
    }

    @Test func weightIsCountNormalisedToBusiest() {
        let far = offset(base, metresNorth: 300, metresEast: 0)
        let coords = Array(repeating: base, count: 5) + [far]     // 5 visits vs 1
        let cells = HeatmapBinning.bin(coords, cellMeters: 25)
        let busy = try! #require(cells.first { $0.count == 5 })
        let sparse = try! #require(cells.first { $0.count == 1 })
        #expect(busy.weight == 1.0)
        #expect(abs(sparse.weight - 0.2) < 1e-9)                  // 1/5
        #expect(busy.weight > sparse.weight)                      // monotonic
    }

    @Test func cellCentreSitsNearItsInputs() throws {
        let cell = try #require(HeatmapBinning.bin([base], cellMeters: 25).first)
        let centre = GeoPoint(lat: cell.lat, lon: cell.lon)
        #expect(centre.distance(to: base) < 25)                   // within one cell of the fix
    }
}
