import Foundation

/// Projects race finish times from current running fitness (running-excellence R4). Deterministic: the
/// Riegel endurance model (T ∝ distance^1.06 — the same exponent `PlanEngine.riegelP5k` uses) extrapolated
/// from a 5k-equivalent pace. It's a flat-course, even-pacing estimate; the real day shifts with terrain,
/// weather, and fueling — the coach narrates that caveat, the engine just computes the number.
enum RacePredictor {
    /// Riegel fatigue exponent (endurance-standard; matches the plan's pace calibration).
    static let exponent = 1.06

    struct Prediction: Identifiable, Equatable, Sendable {
        let distance: RaceDistance
        let timeS: Double
        let paceSPerKm: Double
        var id: String { distance.rawValue }
    }

    /// Projected finishes for every standard race distance from a 5k-equivalent pace (s/km).
    static func predictions(p5kSPerKm: Double) -> [Prediction] {
        guard p5kSPerKm.isFinite, p5kSPerKm > 0 else { return [] }
        let t5k = p5kSPerKm * 5                          // seconds to cover 5 km
        return RaceDistance.allCases.map { d in
            let timeS = t5k * pow(d.meters / 5_000, exponent)
            return Prediction(distance: d, timeS: timeS, paceSPerKm: timeS / (d.meters / 1_000))
        }
    }

    /// Prefer the Athlete Model's learned fitness proxy; fall back to the plan's calibrated pace. Pure
    /// `Double?` inputs so the engine stays free of SwiftData.
    static func predictions(p5kEquivSPerKm: Double?, planP5kSPerKm: Double?) -> [Prediction] {
        guard let p5k = p5kEquivSPerKm ?? planP5kSPerKm, p5k > 0 else { return [] }
        return predictions(p5kSPerKm: p5k)
    }
}
