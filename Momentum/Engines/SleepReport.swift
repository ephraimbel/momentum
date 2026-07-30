import Foundation

/// Sleep through a training lens (Recovery Hub plan §4.4) — last night's report plus the two-week
/// context that decides whether it matters: a learned personal need, running debt, and schedule
/// consistency. Duration is the service's union-merge; stages arrive from the single best source
/// or not at all — a duration-only night stays duration-only, the UI never pretends. No population
/// sleep tables anywhere: need is learned from the athlete's own nights and stage norms come from
/// `HealthBaselines` over their own history. Pure + deterministic; `nil` always means "not enough
/// data yet", never zero.
struct SleepReport: Sendable {

    /// One night as `HealthService.sleepNights` reports it (date, union-merged duration,
    /// best-source stages, in-bed time) plus the night's outer asleep window (earliest
    /// fall-asleep → final wake, the service's `nightSpans`) for the midpoint math — a pure
    /// mirror so the engine never sees HealthKit. Hours for duration (the shipped
    /// `RecoverySignals.sleepHours` convention); seconds for everything else. One record per
    /// wake-up morning, the service's shape.
    struct Night: Sendable, Equatable {
        let date: Date          // local day the night ended — the wake-up morning
        let asleepH: Double     // union-merged across every source; each minute counted once
        let coreS: Double?      // stage seconds from the single best source; all nil = duration-only
        let deepS: Double?
        let remS: Double?
        let awakeS: Double?
        let inBedS: Double?     // union-merged in-bed time; nil when no source wrote it
        let sleepStart: Date?   // outer asleep window; nil when the service can't say
        let sleepEnd: Date?

        init(date: Date, asleepH: Double, coreS: Double? = nil, deepS: Double? = nil,
             remS: Double? = nil, awakeS: Double? = nil, inBedS: Double? = nil,
             sleepStart: Date? = nil, sleepEnd: Date? = nil) {
            self.date = date
            self.asleepH = asleepH
            self.coreS = coreS
            self.deepS = deepS
            self.remS = remS
            self.awakeS = awakeS
            self.inBedS = inBedS
            self.sleepStart = sleepStart
            self.sleepEnd = sleepEnd
        }
    }

    /// Last night's stage breakdown (seconds, single best source). Present only when a source
    /// actually wrote stages that night.
    struct Stages: Sendable, Equatable {
        let coreS: Double
        let deepS: Double
        let remS: Double
        let awakeS: Double
    }

    /// Three no-shame quality tiers — never a red "failed" state; `low` words as "worth an
    /// earlier night", not a scolding.
    enum Band: String, Sendable {
        case good = "Good"
        case fair = "Fair"
        case low = "Low"
    }

    /// Last night's stage share against the athlete's own norm (mean ± 1 SD via
    /// `HealthBaselines`) — personal bands only, never a population deep/REM table.
    enum StageBand: String, Sendable {
        case belowNorm = "Below your norm"
        case inNorm = "In your norm"
        case aboveNorm = "Above your norm"
    }

    // MARK: Last night

    /// Wake-up morning of the night this report headlines — the most recent night on record,
    /// which is not always yesterday (the UI decides how to label a stale one).
    let date: Date
    /// Union-merged asleep hours.
    let asleepH: Double
    /// Stage breakdown, or nil for a duration-only night — the SleepCard renders a single-tone
    /// bar instead of pretending.
    let stages: Stages?
    /// 100 × asleep ÷ in-bed, capped at 100 (a second source's asleep span can outrun the only
    /// in-bed record); nil when no source wrote in-bed time.
    let efficiencyPct: Double?
    /// Deep / REM share of last night's staged sleep (%). Present whenever last night has
    /// stages — rendered with NO band until the personal norm is learned (§4.4).
    let deepPct: Double?
    let remPct: Double?

    // MARK: Context

    /// Nightly need in hours. 8.0 until 14 plausible nights (4–12 h — naps and artifacts
    /// excluded) accrue inside 60 days; then the median of those nights, clamped to 7–9 h.
    let needH: Double
    /// Σ shortfall vs need over the last 14 days — PRESENT nights only. A missing night is
    /// skipped, never counted as zero sleep; a long night never banks credit (shortfall clamps
    /// at 0 — §7's "an earlier night beats a weekend lie-in").
    let debt14H: Double
    /// Circular SD of the last 14 days' sleep midpoints, in minutes — nil until 5 windowed
    /// nights. Clock times live on a circle, so 23:30 vs 00:30 reads as 60 minutes, not 23 hours.
    let midpointDriftMin: Double?
    /// Stage-carrying nights inside the 60-day window — the "learning your norm, 6 of 10" counter.
    let stageNightCount: Int

    // MARK: Quality bands (§4.4 cuts)

    /// Duration vs need: within 30 min of need reads as met (good); ≤ 1.5 h short fair; else low.
    let durationBand: Band
    /// ≥ 90 good · ≥ 80 fair · else low; nil when efficiency is unknowable.
    let efficiencyBand: Band?
    /// < 2 h good · 2–5 h fair · else low.
    let debtBand: Band
    /// ≤ 45 min good · 45–90 fair · else low; nil while drift is unknowable.
    let consistencyBand: Band?
    /// nil until 10 stage-nights (and only when last night has stages) — before that the values
    /// render bandless with "learning your norm".
    let deepBand: StageBand?
    let remBand: StageBand?

    // MARK: Tunables (plan §4.4)

    private static let defaultNeedH = 8.0
    private static let needBounds = 7.0...9.0
    private static let needMinNights = 14
    private static let needWindowDays = 60
    private static let plausibleNightH = 4.0...12.0   // below = nap, above = artifact — need learning only
    private static let recentWindowDays = 14          // debt + consistency window
    private static let driftMinNights = 5
    private static let stageBandMinNights = 10

    /// The report over the athlete's recent nights, or nil when there is no usable night at all —
    /// the SleepCard renders its designed empty state off nil rather than a fake number.
    /// Future-keyed records (an in-progress early bedtime the service files under tomorrow
    /// morning) are dropped, like future-dated junk everywhere else.
    static func build(from nights: [Night],
                      now: Date = Date(),
                      calendar: Calendar = .current) -> SleepReport? {
        let today = calendar.startOfDay(for: now)
        let dated: [(night: Night, age: Int)] = nights.compactMap { night in
            guard let age = calendar.dateComponents([.day],
                                                    from: calendar.startOfDay(for: night.date),
                                                    to: today).day,
                  age >= 0 else { return nil }
            return (night, age)
        }
        guard let latest = dated.min(by: { $0.age < $1.age })?.night else { return nil }
        let inWindow = dated.filter { $0.age <= needWindowDays }
        let recent = dated.filter { $0.age < recentWindowDays }   // ages 0…13 — the last 14 mornings

        // Need: learned from plausible nights only — a 90-minute nap-only day or a 13-hour
        // watch artifact must never teach the athlete they "need" that.
        let plausible = inWindow.filter { plausibleNightH.contains($0.night.asleepH) }
            .map { $0.night.asleepH }
        let needH = plausible.count >= needMinNights
            ? min(needBounds.upperBound, max(needBounds.lowerBound, median(plausible)))
            : defaultNeedH

        // Debt: present nights only. Zero-filling missing mornings would invent a full night of
        // debt for every day the watch stayed on the charger.
        let debt14H = recent.reduce(0.0) { $0 + max(0, needH - $1.night.asleepH) }

        // Consistency: circular SD of the sleep-window midpoints — the angle/vector method, so a
        // schedule straddling midnight reads in minutes, never in hours.
        let midpoints = recent.compactMap { entry -> Double? in
            guard let start = entry.night.sleepStart, let end = entry.night.sleepEnd,
                  end > start else { return nil }
            let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let c = calendar.dateComponents([.hour, .minute, .second], from: mid)
            return Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0) + Double(c.second ?? 0) / 60
        }
        let midpointDriftMin = midpoints.count >= driftMinNights
            ? circularSDMinutes(midpoints) : nil

        // Last night's face value — never inferred, never blended across nights.
        let hasStages = latest.coreS != nil || latest.deepS != nil
            || latest.remS != nil || latest.awakeS != nil
        let stages = hasStages
            ? Stages(coreS: latest.coreS ?? 0, deepS: latest.deepS ?? 0,
                     remS: latest.remS ?? 0, awakeS: latest.awakeS ?? 0)
            : nil
        let efficiencyPct: Double? = latest.inBedS.flatMap { inBed in
            inBed > 0 ? min(100, latest.asleepH * 3_600 / inBed * 100) : nil
        }
        let latestShares = stageShares(latest)

        // Stage bands: only once 10 stage-nights have taught a personal norm (§4.4 — the
        // HealthBaselines 7-day band floor is deliberately raised here; sleep architecture is
        // noisier night-to-night than a vital). Before that, values render with no band.
        let stagedNights = inWindow.compactMap { entry in
            stageShares(entry.night).map { (day: entry.night.date, deep: $0.deep, rem: $0.rem) }
        }
        var deepBand: StageBand?
        var remBand: StageBand?
        if stagedNights.count >= stageBandMinNights, let latestShares,
           let deepBase = HealthBaselines.build(from: stagedNights.map { (day: $0.day, value: $0.deep) },
                                                windowDays: needWindowDays, now: now, calendar: calendar),
           let remBase = HealthBaselines.build(from: stagedNights.map { (day: $0.day, value: $0.rem) },
                                               windowDays: needWindowDays, now: now, calendar: calendar) {
            deepBand = band(latestShares.deep, vs: deepBase)
            remBand = band(latestShares.rem, vs: remBase)
        }

        let shortfallH = needH - latest.asleepH
        return SleepReport(
            date: latest.date,
            asleepH: latest.asleepH,
            stages: stages,
            efficiencyPct: efficiencyPct,
            deepPct: latestShares?.deep,
            remPct: latestShares?.rem,
            needH: needH,
            debt14H: debt14H,
            midpointDriftMin: midpointDriftMin,
            stageNightCount: stagedNights.count,
            durationBand: shortfallH <= 0.5 ? .good : (shortfallH <= 1.5 ? .fair : .low),
            efficiencyBand: efficiencyPct.map { $0 >= 90 ? .good : ($0 >= 80 ? .fair : .low) },
            debtBand: debt14H < 2 ? .good : (debt14H <= 5 ? .fair : .low),
            consistencyBand: midpointDriftMin.map { $0 <= 45 ? .good : ($0 <= 90 ? .fair : .low) },
            deepBand: deepBand,
            remBand: remBand)
    }

    // MARK: Internals

    /// Deep/REM as a share of the stage source's own asleep total (core + deep + REM — awake is
    /// not sleep). The union `asleepH` can be longer than any one source's night, so percentages
    /// stay internally consistent by using the stage source's own denominator. nil for
    /// duration-only nights or an all-zero breakdown.
    private static func stageShares(_ night: Night) -> (deep: Double, rem: Double)? {
        guard night.coreS != nil || night.deepS != nil || night.remS != nil else { return nil }
        let total = (night.coreS ?? 0) + (night.deepS ?? 0) + (night.remS ?? 0)
        guard total > 0 else { return nil }
        return (deep: 100 * (night.deepS ?? 0) / total, rem: 100 * (night.remS ?? 0) / total)
    }

    /// Circular standard deviation of clock times, in minutes — the angle/vector method. Each
    /// midpoint becomes a point on the 24 h unit circle (23:30 and 00:30 sit 60 minutes apart,
    /// not 23 hours); SD = √(−2 ln R̄) of the mean resultant length, mapped back to minutes.
    /// Capped at 720 — beyond half a day apart, "consistency" has no meaning left to measure.
    private static func circularSDMinutes(_ minutesOfDay: [Double]) -> Double {
        let n = Double(minutesOfDay.count)
        var sumCos = 0.0, sumSin = 0.0
        for m in minutesOfDay {
            let angle = m / 1_440 * 2 * .pi
            sumCos += cos(angle)
            sumSin += sin(angle)
        }
        // Identical midpoints can float a hair past R = 1 (ln would go positive → NaN); clamp.
        let r = min(1, (sumCos * sumCos + sumSin * sumSin).squareRoot() / n)
        guard r > 0.000_001 else { return 720 }   // fully scattered — the cap, not infinity
        return min(720, (-2 * log(r)).squareRoot() * 1_440 / (2 * .pi))
    }

    /// A value against a learned norm: outside mean ± 1 SD in either direction is worth a word.
    private static func band(_ value: Double, vs baseline: HealthBaselines.Baseline) -> StageBand {
        if value < baseline.lower { .belowNorm }
        else if value > baseline.upper { .aboveNorm }
        else { .inNorm }
    }

    /// Median of a non-empty set; even counts take the midpoint of the middle pair.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
