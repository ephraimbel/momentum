import Foundation

/// VO₂max estimation (running-excellence R5). Two independent, well-established estimators — from a
/// recent maximal race effort (Daniels' VDOT) and from the heart-rate ratio (Uth–Sørensen) — so the
/// app can show a fitness ceiling even before a race is run. Pure + deterministic. Not a clinical
/// measurement; an estimate to track trend against.
enum VO2maxEstimator {
    // (The Uth–Sørensen `fromHeartRate` alternative was never wired — deleted 2026-08-06;
    // `.fromRace` is the one estimator the app ships.)

    /// Daniels' VDOT from a recent (near-)maximal race effort: model the effort's VO₂ demand and the
    /// fraction of VO₂max sustainable for its duration, then divide. `distanceM` over `timeS`.
    static func fromRace(distanceM: Double, timeS: Double) -> Double? {
        guard distanceM > 0, timeS > 0 else { return nil }
        let velocity = distanceM / (timeS / 60.0)          // m/min
        let tMin = timeS / 60.0
        let percentMax = 0.8
            + 0.1894393 * exp(-0.012778 * tMin)
            + 0.2989558 * exp(-0.1932605 * tMin)
        let vo2 = -4.60 + 0.182258 * velocity + 0.000104 * velocity * velocity
        guard percentMax > 0 else { return nil }
        return vo2 / percentMax
    }
}
