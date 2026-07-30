import Foundation

/// Race-time prediction (running-excellence R4). Projects the athlete's likely finish for their goal
/// race from current fitness — their calibrated 5k-equivalent pace (`plan.p5kSPerKm`, which the plan
/// engine seeds and `PlanCoaching.recalibratePaces` sharpens from strong runs) — using Riegel's
/// endurance model: T₂ = T₁·(D₂/D₁)^1.06, the same relationship the plan engine inverts to derive P5k.
///
/// Pure + deterministic. Conservative by construction (assumes a flat course + good conditions);
/// it's an estimate to train toward, never a medical or performance guarantee.
enum RacePredictor {
    /// Riegel's fatigue exponent — matches `PlanEngine.riegelP5k`, so prediction and pace-seeding stay
    /// inverses of one another. Validated to the marathon; the endurance correction below carries the
    /// honesty past it.
    static let riegelExponent = 1.06

    /// Projected finish time (seconds) for `raceDistanceM`, from a 5k-equivalent pace (s/km).
    /// Predictions running past ~3 h take the endurance tax (`DanielsPaces.enduranceCorrected`):
    /// Riegel's exponent, like the Daniels curve, ignores glycogen, impact damage, and the long
    /// day — without the tax a 50K predicts barely slower than marathon pace, which no one runs.
    static func finishTimeS(raceDistanceM: Double, p5kSPerKm: Double) -> Double? {
        guard raceDistanceM > 0, p5kSPerKm > 0 else { return nil }
        let t5kS = p5kSPerKm * 5.0
        return DanielsPaces.enduranceCorrected(raceTimeS: t5kS * pow(raceDistanceM / 5000.0, riegelExponent))
    }

    /// Projected average race pace (s/km).
    static func projectedPaceSPerKm(raceDistanceM: Double, p5kSPerKm: Double) -> Double? {
        guard let t = finishTimeS(raceDistanceM: raceDistanceM, p5kSPerKm: p5kSPerKm),
              raceDistanceM > 0 else { return nil }
        return t / (raceDistanceM / 1000.0)
    }

    /// Whole days from `now` to race day (≥ 0). nil when there's no date or it's already passed.
    static func daysUntil(raceDate: Date?, from now: Date, calendar: Calendar = .current) -> Int? {
        guard let raceDate else { return nil }
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: raceDate)).day ?? -1
        return days >= 0 ? days : nil
    }

    /// Short label for a race distance ("5K" / "10K" / "Half" / "Marathon" / "Ultra").
    static func label(forRaceM m: Double) -> String {
        switch m {
        case ..<6_000:  "5K"
        case ..<12_000: "10K"
        case ..<25_000: "Half"
        case ..<45_000: "Marathon"
        default:        "Ultra"
        }
    }
}
