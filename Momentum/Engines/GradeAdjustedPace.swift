import Foundation

/// Grade-Adjusted Pace (running-excellence R5). Hills distort raw pace — a slow climb can be a bigger
/// effort than a fast flat. GAP converts an on-grade pace to the flat pace that would cost the same
/// energy, using Minetti et al. (2002)'s metabolic cost-of-running curve. Pure + deterministic; lets
/// a hilly run be compared fairly against a flat one (and feeds honest Pace Insights on rolling routes).
enum GradeAdjustedPace {
    /// Metabolic cost of running at gradient `i` (rise/run; 0.10 = 10% up) **relative to flat**.
    /// Minetti's 5th-order polynomial (J·kg⁻¹·m⁻¹) normalized so flat = 1.0.
    static func costRatio(grade i: Double) -> Double {
        let c = 155.4 * pow(i, 5) - 30.4 * pow(i, 4) - 43.3 * pow(i, 3)
              + 46.3 * i * i + 19.5 * i + 3.6
        return c / 3.6   // C(0) = 3.6 → flat ratio 1.0
    }

    /// Flat-equivalent pace (s/km) for a segment run at `paceSPerKm` on `grade` (rise/run). Uphill →
    /// a *faster* equivalent (you worked harder than the clock shows); downhill → slower.
    static func adjustedPaceSPerKm(paceSPerKm: Double, grade: Double) -> Double? {
        guard paceSPerKm > 0 else { return nil }
        let ratio = costRatio(grade: grade)
        guard ratio > 0 else { return nil }
        return paceSPerKm / ratio
    }

    /// GAP for a whole run from per-segment (distanceM, pace, grade) samples — a distance-weighted
    /// blend of each segment's flat-equivalent pace. nil when there's no valid distance.
    static func runGAPSPerKm(_ segments: [(distanceM: Double, paceSPerKm: Double, grade: Double)]) -> Double? {
        var weightedTime = 0.0, totalDistanceKm = 0.0
        for s in segments {
            guard s.distanceM > 0, let gap = adjustedPaceSPerKm(paceSPerKm: s.paceSPerKm, grade: s.grade) else { continue }
            let km = s.distanceM / 1000.0
            weightedTime += gap * km
            totalDistanceKm += km
        }
        guard totalDistanceKm > 0 else { return nil }
        return weightedTime / totalDistanceKm
    }
}
