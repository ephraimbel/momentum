import Foundation

/// Plate math (PRD §22). Descending greedy fill of `(target − bar)/2` per side; if a remainder
/// can't be made from the available plates, report the total shortfall (e.g. "+1.1 kg short").
/// Unit-agnostic: pass plate/bar weights already in the user's display unit.
enum PlateCalculator {
    struct Plate: Equatable { let weight: Double; let count: Int }
    struct Result: Equatable {
        /// Plates to load on **each** side, heaviest first.
        let perSide: [Plate]
        /// Total weight that couldn't be made (both sides), 0 if exact.
        let totalShortfall: Double
        var isExact: Bool { totalShortfall == 0 }
    }

    static let kgPlates: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]
    static let lbPlates: [Double] = [45, 35, 25, 10, 5, 2.5]
    static let defaultBarKg = 20.0
    static let defaultBarLb = 45.0

    static func compute(target: Double, bar: Double, available: [Double]) -> Result {
        guard target > bar else { return Result(perSide: [], totalShortfall: 0) }
        let eps = 1e-6
        var remainingPerSide = (target - bar) / 2
        var plates: [Plate] = []

        for plate in available.sorted(by: >) where plate <= remainingPerSide + eps {
            let count = Int((remainingPerSide + eps) / plate)
            guard count > 0 else { continue }
            plates.append(Plate(weight: plate, count: count))
            remainingPerSide -= Double(count) * plate
        }

        let shortfall = remainingPerSide > eps ? (remainingPerSide * 2) : 0
        // Round to kill FP fuzz (e.g. 1.0999999).
        let rounded = (shortfall * 1000).rounded() / 1000
        return Result(perSide: plates, totalShortfall: rounded)
    }
}
