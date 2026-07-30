import Foundation

/// Personal baselines for overnight vitals (Recovery Hub plan §4.1) — the "your own normal" every
/// Health-hub engine reads before it dares call a number high or low. Built from day-bucketed
/// Health history: one value per local day (median — multi-source days count once), mean +
/// population SD, and **one** winsorization pass (clamp beyond ±3 SD, recompute) so a single
/// 200 ms HRV artifact dies without a second pass ever eating a real trend. No population tables
/// anywhere — every band is learned from the athlete's own nights. Pure + deterministic.
enum HealthBaselines {
    /// Trailing look-back per signal (days). The slow-moving vitals (wrist temperature, walking HR)
    /// earn a longer memory; the nervous-system signals stay tight so a real trend shows in a month.
    enum Window {
        static let hrv = 30
        static let restingHR = 30
        static let respiratoryRate = 30
        static let wristTemperature = 60
        static let walkingHR = 60
    }

    /// A learned norm for one signal. `lower`/`upper` draw the personal-band ribbon;
    /// `z(_:)` scores this morning's value against it.
    struct Baseline: Equatable, Sendable {
        let mean: Double
        let sd: Double            // population SD, post-winsorization
        let dayCount: Int         // distinct local days that contributed a value
        let windowDays: Int

        /// The personal band — mean ± 1 SD — rendered behind sparklines as "your normal".
        var lower: Double { mean - sd }
        var upper: Double { mean + sd }
        /// ≥ 7 days — enough history to draw a band at all.
        var isBanded: Bool { dayCount >= 7 }
        /// ≥ 14 days — enough to trust deviations (readiness modifiers may fire from here).
        var isEstablished: Bool { dayCount >= 14 }

        /// Standard score of a value against this norm; 0 for a flat baseline (÷0 guard, never NaN).
        func z(_ value: Double) -> Double {
            sd > 0.000_1 ? (value - mean) / sd : 0
        }
    }

    /// The baseline over the trailing window, or nil when no value lands inside it — engines render
    /// a "learning you" state off nil rather than ever inventing a norm. A value from exactly
    /// `windowDays` days ago still counts; day `windowDays + 1` is the cutoff. Future-dated junk
    /// is dropped.
    static func build(from dailyValues: [(day: Date, value: Double)],
                      windowDays: Int,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> Baseline? {
        // One value per local day — multi-source days (Watch + Oura + Whoop all wrote) collapse
        // to the median so a triple-writing morning can't outvote a single-device one.
        let today = calendar.startOfDay(for: now)
        var samplesByDay: [Date: [Double]] = [:]
        for (day, value) in dailyValues {
            let key = calendar.startOfDay(for: day)
            guard let age = calendar.dateComponents([.day], from: key, to: today).day,
                  age >= 0, age <= windowDays else { continue }
            samplesByDay[key, default: []].append(value)
        }
        guard !samplesByDay.isEmpty else { return nil }
        let daily = samplesByDay.values.map(median)

        // One winsorization pass: clamp anything beyond ±3 SD to the bound and recompute.
        // A single pass kills artifacts; iterating to convergence would start eating real trends.
        let first = meanAndSD(daily)
        let lo = first.mean - 3 * first.sd
        let hi = first.mean + 3 * first.sd
        let final = meanAndSD(daily.map { min(max($0, lo), hi) })

        return Baseline(mean: final.mean, sd: final.sd,
                        dayCount: daily.count, windowDays: windowDays)
    }

    // MARK: Internals

    /// Median of a non-empty set; even counts take the midpoint of the middle pair.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func meanAndSD(_ values: [Double]) -> (mean: Double, sd: Double) {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }
}
