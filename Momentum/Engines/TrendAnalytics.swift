import Foundation

/// Pro-grade trend analytics (running-excellence R5+) — the numeric series behind the Trends
/// page's premium layer. Pure + deterministic; all values SI (meters, seconds, spm, bpm) so the
/// view formats at display time. Builds on the existing `FitnessFreshness`, `TrainingLoad`, and
/// stored `GPSDetail` fields (`avgCadence`, `elevationGainM`, `hrSamples`) that the app captures
/// but never charted.
enum TrendAnalytics {

    // MARK: Value types

    /// One day of the fitness/fatigue/form (CTL·ATL·TSB) curve.
    struct DayPoint: Identifiable, Equatable, Sendable {
        let date: Date
        let ctl: Double   // fitness
        let atl: Double   // fatigue
        var tsb: Double { ctl - atl }  // form
        var id: Date { date }
    }

    /// One point of a weekly series (rolling 7-day window ending on `weekStart + 7d`).
    struct WeekValue: Identifiable, Equatable, Sendable {
        let weekStart: Date
        let value: Double     // SI; 0 = an empty week (kept so the timeline never has gaps)
        var id: Date { weekStart }
    }

    /// A compact summary tile: the current value, its short trend, and a sparkline. `available`
    /// is false when the athlete hasn't captured the data yet (e.g. no cadence/HR) — the tile
    /// shows a calm "—" instead of a fake number.
    struct SummaryMetric: Identifiable, Equatable, Sendable {
        enum Kind: String, CaseIterable, Sendable {
            case fitness, form, load, cadence, climb, efficiency
        }
        let kind: Kind
        let value: Double
        let trendPct: Double?     // vs the baseline window; nil when there isn't enough history
        let spark: [Double]       // oldest → newest, for the mini line
        let available: Bool
        var id: String { kind.rawValue }
    }

    // MARK: Fitness / Fatigue / Form (the marquee curve)

    /// The daily CTL/ATL/TSB curve over the trailing `days` (default ~4 months). Buckets each
    /// workout's Foster session load onto its local day, then runs the impulse-response model —
    /// the same daily loads `ProgressView` already computes for the single "current" value, but
    /// kept as the full series for charting.
    static func fitnessFreshness(workouts: [Workout], days: Int = 120,
                                 now: Date = Date(), calendar: Calendar = .current) -> [DayPoint] {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var buckets: [Date: Double] = [:]
        for w in workouts where w.startedAt >= start {
            buckets[calendar.startOfDay(for: w.startedAt), default: 0] += TrainingLoad.session(w)
        }
        let dayList = (0..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let loads = dayList.map { buckets[calendar.startOfDay(for: $0)] ?? 0 }
        return zip(dayList, FitnessFreshness.series(dailyLoads: loads))
            .map { DayPoint(date: $0.0, ctl: $0.1.ctl, atl: $0.1.atl) }
    }

    // MARK: Weekly series (rolling 7-day windows ending now — matches ProgressInsights)

    /// `weeks` rolling 7-day windows, oldest → newest, each carrying the reduction of the runs
    /// that fall inside it. `reduce` gets the in-window GPS workouts and returns the SI value
    /// (0 for an empty week is fine — the caller decides how to render gaps).
    private static func weekly(_ workouts: [Workout], weeks: Int, now: Date, calendar: Calendar,
                               reduce: ([Workout]) -> Double) -> [WeekValue] {
        let today = calendar.startOfDay(for: now)
        return (0..<weeks).reversed().compactMap { i -> WeekValue? in
            guard let end = calendar.date(byAdding: .day, value: -7 * i, to: today),
                  let start = calendar.date(byAdding: .day, value: -7, to: end) else { return nil }
            let inWeek = workouts.filter { $0.startedAt > start && $0.startedAt <= end }
            return WeekValue(weekStart: start, value: reduce(inWeek))
        }
    }

    /// Weekly average running cadence (spm) — the mean of each run's `avgCadence`, run-count
    /// weighted. Empty weeks read 0 (the view skips them for the average line).
    static func weeklyCadence(workouts: [Workout], weeks: Int = 12,
                              now: Date = Date(), calendar: Calendar = .current) -> [WeekValue] {
        weekly(workouts, weeks: weeks, now: now, calendar: calendar) { runs in
            var cadences: [Double] = []
            for w in runs where w.type.discipline == .running {
                if let c = w.gps?.avgCadence, c > 0 { cadences.append(Double(c)) }
            }
            guard !cadences.isEmpty else { return 0 }
            return cadences.reduce(0, +) / Double(cadences.count)
        }
    }

    /// Weekly total climb (meters) — the sum of every GPS workout's `elevationGainM`.
    static func weeklyClimb(workouts: [Workout], weeks: Int = 12,
                            now: Date = Date(), calendar: Calendar = .current) -> [WeekValue] {
        weekly(workouts, weeks: weeks, now: now, calendar: calendar) { runs in
            runs.compactMap { $0.gps?.elevationGainM }.reduce(0, +)
        }
    }

    // MARK: Aerobic decoupling (cardiac drift) — a fitness quality metric

    /// Aerobic decoupling for one steady run: how much the heart-rate-to-pace ratio drifts from
    /// the first half to the second. Low (<5%) means you held pace without the heart climbing —
    /// aerobically fit. Needs both a heart-rate series and GPS speed (Watch/strap runs). Returns
    /// nil for intervals, short runs, or missing data (never a misleading number).
    static func decoupling(_ workout: Workout, calendar: Calendar = .current) -> Double? {
        guard workout.type.discipline == .running, let gps = workout.gps else { return nil }
        let hr = gps.hrSamples.filter { $0.bpm > 0 }.sorted { $0.t < $1.t }
        let loc = gps.samples.filter { $0.accepted && $0.speedMS > 0.5 }.sorted { $0.t < $1.t }
        guard hr.count >= 20, loc.count >= 20,
              let firstT = [hr.first?.t, loc.first?.t].compactMap({ $0 }).min(),
              let lastT = [hr.last?.t, loc.last?.t].compactMap({ $0 }).max() else { return nil }
        let elapsed = lastT.timeIntervalSince(firstT)
        guard elapsed >= 20 * 60 else { return nil }   // steady aerobic efforts only
        let mid = firstT.addingTimeInterval(elapsed / 2)

        func ratio(_ from: Date, _ to: Date) -> Double? {
            let hrs = hr.filter { $0.t >= from && $0.t < to }.map { Double($0.bpm) }
            let spd = loc.filter { $0.t >= from && $0.t < to }.map(\.speedMS)
            guard hrs.count >= 5, spd.count >= 5 else { return nil }
            let meanHR = hrs.reduce(0, +) / Double(hrs.count)
            let meanSpeed = spd.reduce(0, +) / Double(spd.count)
            guard meanSpeed > 0 else { return nil }
            return meanHR / meanSpeed   // bpm per m/s — rises when HR drifts up at the same pace
        }
        guard let r1 = ratio(firstT, mid), let r2 = ratio(mid, lastT), r1 > 0 else { return nil }
        return (r2 - r1) / r1 * 100
    }

    /// Decoupling for each qualifying run in the window, oldest → newest — a "getting more
    /// efficient" trend (falling is better).
    static func recentDecoupling(workouts: [Workout], limit: Int = 10) -> [WeekValue] {
        workouts
            .filter { $0.type.discipline == .running }
            .sorted { $0.startedAt < $1.startedAt }
            .compactMap { w in decoupling(w).map { WeekValue(weekStart: w.startedAt, value: $0) } }
            .suffix(limit)
            .map { $0 }
    }

    // MARK: Summary tiles (the at-a-glance strip)

    /// The six premium metrics as compact tiles. Each carries a raw SI current value, a sparkline,
    /// and a trend vs the older half of its own history. The view maps `kind` → label/unit/format.
    static func summary(workouts: [Workout], now: Date = Date(), calendar: Calendar = .current) -> [SummaryMetric] {
        let ff = fitnessFreshness(workouts: workouts, now: now, calendar: calendar)
        // Sample the daily curve weekly (every 7th day) so the sparklines are ~12–17 points.
        let ffWeekly = stride(from: max(0, ff.count - 84), to: ff.count, by: 7).map { ff[$0] }
        let load = weekly(workouts, weeks: 12, now: now, calendar: calendar) { runs in
            runs.reduce(0) { $0 + TrainingLoad.session($1) }
        }
        let cadence = weeklyCadence(workouts: workouts, now: now, calendar: calendar)
        let climb = weeklyClimb(workouts: workouts, now: now, calendar: calendar)
        let decoup = recentDecoupling(workouts: workouts)

        func metric(_ kind: SummaryMetric.Kind, _ spark: [Double], current: Double? = nil) -> SummaryMetric {
            let clean = spark.filter { $0 != 0 || kind == .form }   // form can legitimately be ~0
            let value = current ?? clean.last ?? 0
            let available = !clean.isEmpty
            return SummaryMetric(kind: kind, value: value, trendPct: trend(clean),
                                 spark: spark, available: available)
        }

        return [
            metric(.fitness, ffWeekly.map(\.ctl), current: ff.last?.ctl),
            metric(.form, ffWeekly.map(\.tsb), current: ff.last?.tsb),
            metric(.load, load.map(\.value)),
            metric(.cadence, cadence.map(\.value)),
            metric(.climb, climb.map(\.value)),
            metric(.efficiency, decoup.map(\.value)),
        ]
    }

    /// Percent change of the recent third vs the prior third of a series — a stable read that
    /// ignores single-point noise. nil when there's too little (or zero-baseline) history.
    static func trend(_ values: [Double]) -> Double? {
        let v = values.filter { $0.isFinite }
        guard v.count >= 4 else { return nil }
        let third = max(1, v.count / 3)
        let recent = Array(v.suffix(third))
        let prior = Array(v.prefix(third))
        let rMean = recent.reduce(0, +) / Double(recent.count)
        let pMean = prior.reduce(0, +) / Double(prior.count)
        guard abs(pMean) > 0.0001 else { return nil }
        return (rMean - pMean) / abs(pMean) * 100
    }
}
