import Foundation

/// Long-run + race fueling guidance (ENDURANCE-FOCUS §11) — the evidence-based consensus, encoded:
/// under an hour needs nothing but water; 1–2.5 h wants 30–60 g carbs/hr; beyond 2.5 h wants 60–90
/// g/hr with a trained gut. General and deterministic — **fueling, not dieting**: no calories, no
/// macros, no personalization by body, never medical advice.
enum FuelingGuide {

    struct Guidance: Sendable, Equatable {
        /// nil → no in-run carbs needed.
        let carbsPerHour: ClosedRange<Int>?
        let headline: String
        let before: String
        let during: String
        let after: String

        static let disclaimer = "General guidance for healthy adults — not medical or nutrition advice."
    }

    /// Duration thresholds (seconds).
    static let carbsFromS: Double = 60 * 60          // < 1 h → water only
    static let highCarbFromS: Double = 150 * 60      // ≥ 2.5 h → the 60–90 g/hr range

    /// Guidance for a session of `durationS`. `isRace` sharpens the tone (practice → execute).
    static func guidance(durationS: Double, isRace: Bool = false) -> Guidance {
        switch durationS {
        case ..<carbsFromS:
            return Guidance(
                carbsPerHour: nil,
                headline: "No fuel needed",
                before: "Run as you are — a light snack an hour out if you're hungry.",
                during: "Water if it's warm; nothing else required under an hour.",
                after: "A normal meal within a couple of hours covers it.")
        case ..<highCarbFromS:
            return Guidance(
                carbsPerHour: 30...60,
                headline: "Fuel every 30–40 minutes",
                before: "A carb-focused meal 2–3 hours out; top up with water before you start.",
                during: isRace
                    ? "30–60 g of carbs per hour — the plan you practiced, from the first 30 minutes. Drink to thirst (roughly 400–800 ml/hr)."
                    : "30–60 g of carbs per hour (a gel or chews every 30–40 min). Drink to thirst — practice this on long runs so race day is automatic.",
                after: "Carbs + some protein within the hour — that's when the rebuild happens.")
        default:
            return Guidance(
                carbsPerHour: 60...90,
                headline: "This one needs a fueling plan",
                before: "Carb-focused meals the day before AND 2–3 hours out. Arrive topped up, not stuffed.",
                during: isRace
                    ? "60–90 g of carbs per hour, starting early — never wait until you feel empty. Drink to thirst; add electrolytes if you're a salty sweater."
                    : "Work up to 60–90 g of carbs per hour — the gut is trainable, so build to it across your long runs. Drink to thirst; electrolytes on hot days.",
                after: "Refuel properly: carbs + protein within the hour, and a real meal after that.")
        }
    }

    /// Estimated duration for a planned session (explicit duration, else distance × pace). nil when
    /// there's nothing to estimate from.
    static func estimatedDurationS(distanceM: Double?, paceSPerKm: Double?, durationS: Double?) -> Double? {
        if let durationS, durationS > 0 { return durationS }
        if let distanceM, distanceM > 0, let paceSPerKm, paceSPerKm > 0 { return distanceM / 1000 * paceSPerKm }
        return nil
    }
}
