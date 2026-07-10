import Foundation

/// Daniels/VDOT training-pace zones (PRD §9.1, PLAN-QUALITY-AUDIT fix #1). Replaces the old fixed
/// additive offsets ("easy = P5k + 80 for everyone") with the curvilinear Daniels–Gilbert model, so a
/// 7-min-miler and an 11-min-miler each get a *proportionally* correct easy/threshold/interval pace.
///
/// The whole model hangs off two published curves (Daniels & Gilbert, *Oxygen Power*, 1979):
///  • oxygen cost of running at velocity v (m/min):  VO₂ = −4.60 + 0.182258·v + 0.000104·v²
///  • fraction of VO₂max sustainable for a t-minute race: %max(t) = 0.8 + 0.1894393·e^(−0.012778·t)
///                                                                      + 0.2989558·e^(−0.1932605·t)
/// VDOT = race VO₂ demand ÷ %max(race duration). Inverting the cost curve at a chosen fraction of
/// VDOT yields each training pace. Zone anchors (Daniels' E/M/T/I bands):
///  • recovery 60% · long 64% · easy 66% VO₂max — the E band, 59–74%
///  • threshold = the intensity you could race for one hour (%max(60) ≈ 88.8%) — Daniels' T
///  • interval  = 100% VO₂max (vVO₂max ≈ an 11-minute race effort) — Daniels' I
///  • marathon  = the *predicted marathon race pace* at this VDOT, solved from the same curves
/// Pure, deterministic, and unit-tested against Daniels' published VDOT-50 table row. The stored
/// fitness scalar stays `p5kSPerKm` (calibration + bounded recalibration already maintain it); VDOT
/// is derived from it on demand, so every existing adaptation loop keeps working unchanged.
enum DanielsPaces {

    // Daniels–Gilbert constants (VO₂ = A·v² + B·v − C, v in m/min).
    private static let A = 0.000104, B = 0.182258, C = 4.60

    /// Oxygen cost (ml/kg/min) of running at `v` m/min.
    static func vo2(atVelocityMPerMin v: Double) -> Double { A * v * v + B * v - C }

    /// Fraction of VO₂max sustainable for a `t`-minute race effort.
    static func percentMax(atMinutes t: Double) -> Double {
        0.8 + 0.1894393 * exp(-0.012778 * t) + 0.2989558 * exp(-0.1932605 * t)
    }

    /// Velocity (m/min) whose oxygen cost is `target` — the cost curve inverted (positive root).
    static func velocityMPerMin(atVO2 target: Double) -> Double {
        (sqrt(B * B + 4 * A * (C + max(0, target))) - B) / (2 * A)
    }

    /// Keep a garbage p5k from producing garbage paces (2:30–15:00 min/km covers every real runner).
    private static func clamped(_ p5kSPerKm: Double) -> Double {
        p5kSPerKm.isFinite ? min(900, max(150, p5kSPerKm)) : 330
    }

    /// VDOT implied by a 5K at `p5kSPerKm` — the (near-)maximal-effort assumption is the same one the
    /// calibration benchmark and `PlanCoaching.recalibratePaces` already make when they set p5k.
    static func vdot(p5kSPerKm: Double) -> Double {
        let p = clamped(p5kSPerKm)
        let tMin = p * 5.0 / 60.0
        return vo2(atVelocityMPerMin: 5000.0 / tMin) / percentMax(atMinutes: tMin)
    }

    /// Zone anchors as fractions of VO₂max.
    static let recoveryFraction = 0.60
    static let longFraction = 0.64
    static let easyFraction = 0.66
    /// Daniels' T = the intensity you could race for about an hour.
    static var thresholdFraction: Double { percentMax(atMinutes: 60) }
    static let intervalFraction = 1.0

    /// Pace (s/km) at a fraction of this VDOT's VO₂max. Unrounded — callers round for display.
    static func paceSPerKm(fractionOfVO2max f: Double, vdot: Double) -> Double {
        let v = velocityMPerMin(atVO2: f * vdot)
        guard v > 0 else { return 900 }
        return 60_000.0 / v
    }

    /// Predicted race pace (s/km) over `distanceM` at this VDOT — bisection on the race-time curve
    /// (demand/%max is strictly decreasing in time, so the root is unique). Powers marathon pace.
    static func racePaceSPerKm(distanceM d: Double, vdot: Double) -> Double? {
        guard d > 0, vdot > 0 else { return nil }
        var lo = d / 600.0, hi = d / 60.0          // race time bounds: 600 → 60 m/min
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            let implied = vo2(atVelocityMPerMin: d / mid) / percentMax(atMinutes: mid)
            if implied > vdot { lo = mid } else { hi = mid }
        }
        let tMin = (lo + hi) / 2
        return tMin * 60.0 / (d / 1000.0)
    }

    /// Marathon pace (s/km) — the M zone: what this athlete could actually race a marathon at.
    static func marathonPaceSPerKm(p5kSPerKm: Double) -> Double {
        racePaceSPerKm(distanceM: 42_195, p5kSPerKm: p5kSPerKm)
    }

    /// Predicted race pace (s/km, whole seconds) at any goal distance from the athlete's 5K —
    /// powers goal-race-pace reps in peak/taper weeks.
    static func racePaceSPerKm(distanceM d: Double, p5kSPerKm: Double) -> Double {
        let raw = racePaceSPerKm(distanceM: d, vdot: vdot(p5kSPerKm: p5kSPerKm)) ?? clamped(p5kSPerKm)
        return max(120, raw.rounded())
    }

    /// The training pace (s/km, whole seconds) for a run type at the athlete's calibrated 5K pace.
    /// `.race` is the 5K race pace itself (race-distance-specific pacing lives in `RacePredictor`).
    static func trainingPace(_ type: RunType, p5kSPerKm: Double) -> Double {
        max(120, rawTrainingPace(type, p5kSPerKm: p5kSPerKm).rounded())
    }

    private static func rawTrainingPace(_ type: RunType, p5kSPerKm: Double) -> Double {
        let p5k = clamped(p5kSPerKm)
        let fraction: Double
        switch type {
        case .recovery: fraction = recoveryFraction
        case .long, .progression: fraction = longFraction
        case .easy, .freeRun, .fartlek, .hills, .strides: fraction = easyFraction
        case .tempo: fraction = thresholdFraction
        case .intervals: fraction = intervalFraction
        case .race: return p5k
        }
        return paceSPerKm(fractionOfVO2max: fraction, vdot: vdot(p5kSPerKm: p5k))
    }

    /// Recover the p5k a session's target pace implies for its run type — the inverse of
    /// `trainingPace`, via bisection (the zone pace is strictly increasing in p5k). Used only when a
    /// caller has a session pace but no plan (e.g. `StructuredWorkoutBuilder` without `p5kSPerKm`).
    static func p5kSPerKm(fromPace pace: Double, type: RunType) -> Double {
        guard pace.isFinite, pace > 0 else { return 330 }
        if type == .race { return clamped(pace) }
        var lo = 150.0, hi = 900.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if rawTrainingPace(type, p5kSPerKm: mid) < pace { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
