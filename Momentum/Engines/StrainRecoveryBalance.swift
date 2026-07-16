import Foundation

/// Strain vs recovery as one picture (Recovery Hub plan §4.5) — the engine behind the hub's
/// signature BalanceCard. Pairs each day's strain (`DayStrain.score`) with its readiness
/// (`MorningReadiness.score`) on a gap-free date spine and names the trailing-7-day pattern:
/// building, balanced, overreaching, or detraining. **Descriptive only** — the action path stays
/// `RecoveryAdaptation.decide`/`tripwire`, which this composes with, never replaces. `ctlDelta7`
/// (the 7-day CTL change) is computed by callers from `TrendAnalytics.fitnessFreshness` and
/// injected — this engine never re-derives the fitness curve. Pure + deterministic.
struct StrainRecoveryBalance: Sendable {
    /// One spine day. Either side may be missing (no workout read that day, no morning signals) —
    /// the chart nil-holes and bridges with a dotted hairline rather than fake a zero.
    struct Day: Equatable, Sendable {
        let date: Date            // local start-of-day
        let strain: Double?       // DayStrain.score, 0–100
        let readiness: Double?    // MorningReadiness.score, 0–100

        /// What the athlete had minus what the day cost — nil when either side is missing,
        /// so a data hole never reads as a real number.
        var balance: Double? {
            guard let readiness, let strain else { return nil }
            return readiness - strain
        }
    }

    /// The card's state word for the trailing week.
    enum State: String, Sendable {
        case building
        case balanced
        case overreaching
        case detraining
        case insufficient
    }

    /// Gap-free date spine, oldest → today, exactly `spineDays` entries (7 or 30 in the UI).
    let days: [Day]
    /// The trailing-7-day pattern; `.insufficient` under 4 valid (both-sided) days —
    /// a mostly-empty week gets a curve, never a verdict.
    let state: State

    init(dailyPairs: [(day: Date, strain: Double?, readiness: Double?)],
         spineDays: Int,
         ctlDelta7: Double,
         now: Date = Date(),
         calendar: Calendar = .current) {
        // Bucket by local day. Callers compute one pair per day, so a duplicate is a caller bug —
        // the later entry wins rather than silently blending two versions of the same day.
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: (strain: Double?, readiness: Double?)] = [:]
        for pair in dailyPairs {
            byDay[calendar.startOfDay(for: pair.day)] = (pair.strain, pair.readiness)
        }

        // The gap-free spine: every calendar day gets a slot and holes stay nil — the chart's
        // dotted-bridge rendering needs missing days *present*, not dropped. Anything outside
        // the spine (too old, or future-dated junk) never lands.
        days = (0..<max(0, spineDays)).reversed().compactMap { daysAgo in
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { return nil }
            let pair = byDay[date]
            return Day(date: date, strain: pair?.strain, readiness: pair?.readiness)
        }

        // d̄ over the trailing 7 = mean of readiness − strain where both exist; half-present
        // days (one side nil) don't count toward the ≥ 4-valid-days bar.
        let deltas = days.suffix(7).compactMap(\.balance)
        guard deltas.count >= 4 else { state = .insufficient; return }
        state = Self.state(meanDelta: deltas.reduce(0, +) / Double(deltas.count),
                           ctlDelta7: ctlDelta7)
    }

    /// Bands d̄ (mean readiness − strain over the trailing 7) into the state word — cuts −10/25/45.
    /// The CTL guard on the top band is what keeps a race-week taper from being scolded as
    /// detraining: a big surplus while fitness still climbs (`ctlDelta7 > 0`) is a plan working.
    static func state(meanDelta dBar: Double, ctlDelta7: Double) -> State {
        switch dBar {
        case ..<(-10):   .overreaching   // spending well past what recovery replaces
        case (-10)..<25: .building       // productive stress — the block is working
        case 25..<45:    .balanced       // strain and recovery trading evenly
        default:         ctlDelta7 > 0 ? .balanced : .detraining
        }
    }
}
