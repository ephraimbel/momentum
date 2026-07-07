import Foundation

/// Fitness / Fatigue / Form — the CTL·ATL·TSB model (running-excellence R5). The standard
/// impulse-response (Banister / TrainingPeaks) view of training: **CTL** (Chronic Training Load, a
/// 42-day exponentially-weighted average of daily load) is fitness; **ATL** (Acute, 7-day) is fatigue;
/// **Form** = CTL − ATL tells you whether you're fresh (positive) or buried (negative). Daily load
/// comes from `TrainingLoad` (Foster session-RPE). Pure + deterministic.
enum FitnessFreshness {
    struct Point: Equatable, Sendable {
        let ctl: Double   // fitness
        let atl: Double   // fatigue
        /// Training Stress Balance ("Form"): >0 fresh, <0 fatigued.
        var tsb: Double { ctl - atl }
    }

    /// The exponentially-weighted CTL/ATL series for a run of **daily** loads in chronological order
    /// (rest days are 0). Seeded from zero — the first weeks read low until history accrues.
    static func series(dailyLoads: [Double], ctlDays: Double = 42, atlDays: Double = 7) -> [Point] {
        guard ctlDays > 0, atlDays > 0 else { return [] }
        let ctlAlpha = 1 - exp(-1 / ctlDays)
        let atlAlpha = 1 - exp(-1 / atlDays)
        var ctl = 0.0, atl = 0.0
        var out: [Point] = []
        out.reserveCapacity(dailyLoads.count)
        for load in dailyLoads {
            ctl += ctlAlpha * (load - ctl)
            atl += atlAlpha * (load - atl)
            out.append(Point(ctl: ctl, atl: atl))
        }
        return out
    }

    /// Today's fitness/fatigue/form from a daily-load history. nil for an empty history.
    static func current(dailyLoads: [Double]) -> Point? {
        series(dailyLoads: dailyLoads).last
    }

    /// A calm, no-shame read of the current Form (TSB) — the coaching narration hook.
    static func formLabel(_ tsb: Double) -> String {
        switch tsb {
        case ..<(-25): "Deep in the work"
        case ..<(-5):  "Building"
        case ...5:     "Balanced"
        case ...20:    "Fresh"
        default:       "Peaked"
        }
    }
}
