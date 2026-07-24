import SwiftUI
import Charts

/// The Trends page's ESSENTIALS layer (2026-07-22 redesign) — the numbers every endurance athlete
/// actually tracks, surfaced Bevel/Oura-style: few cards, one clear answer each, plain-language
/// deltas. This file holds the pure math (`TrendsEssentials`, unit-tested) and the three cards it
/// feeds: the This-Week stat strip, the daily-movement (steps) chart, and the totals card.
///
/// Design doctrine carried over: tabular numerals, transforms-only animation, monochrome ink with
/// iridescence reserved for "you are here" (the current bar), one accessibility element per card.
enum TrendsEssentials {

    // MARK: This week vs last week

    struct WeekStat: Equatable, Sendable {
        var distanceM: Double = 0
        var durationS: Double = 0
        var sessions: Int = 0
        var elevationM: Double = 0
    }

    /// The calendar week `weeksAgo` back from `now` (0 = this week), summed over every workout.
    /// Calendar weeks, not rolling 7-day windows — "this week vs last week" is the sentence
    /// athletes actually say, and it matches the weekly buckets the charts already plot.
    static func weekStat(workouts: [Workout], weeksAgo: Int, now: Date = Date(),
                         calendar: Calendar = .current) -> WeekStat {
        guard let anchor = calendar.date(byAdding: .day, value: -7 * weeksAgo, to: now),
              let week = calendar.dateInterval(of: .weekOfYear, for: anchor) else { return WeekStat() }
        var stat = WeekStat()
        for w in workouts where w.startedAt >= week.start && w.startedAt < week.end {
            stat.sessions += 1
            stat.durationS += w.durationS
            stat.distanceM += w.gps?.distanceM ?? 0
            stat.elevationM += w.gps?.elevationGainM ?? 0
        }
        return stat
    }

    // MARK: Totals (the "how far have I come" numbers)

    struct TotalsBucket: Equatable, Sendable {
        var distanceM: Double = 0
        var durationS: Double = 0
        var sessions: Int = 0
    }

    struct Totals: Equatable, Sendable {
        var month = TotalsBucket()
        var year = TotalsBucket()
        var lifetime = TotalsBucket()
    }

    /// Calendar month, calendar year, and everything ever — one pass over the workouts.
    static func totals(workouts: [Workout], now: Date = Date(),
                       calendar: Calendar = .current) -> Totals {
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let yearStart = calendar.dateInterval(of: .year, for: now)?.start ?? now
        var t = Totals()
        for w in workouts {
            let d = w.gps?.distanceM ?? 0
            t.lifetime.sessions += 1; t.lifetime.durationS += w.durationS; t.lifetime.distanceM += d
            if w.startedAt >= yearStart {
                t.year.sessions += 1; t.year.durationS += w.durationS; t.year.distanceM += d
            }
            if w.startedAt >= monthStart {
                t.month.sessions += 1; t.month.durationS += w.durationS; t.month.distanceM += d
            }
        }
        return t
    }

    // MARK: Daily movement (steps)

    struct StepPoint: Identifiable, Equatable, Sendable {
        let date: Date
        let steps: Double
        var id: Date { date }
    }

    /// Weekly AVERAGES (not sums) for the wide ranges — "you averaged 9.1k steps a day that week"
    /// is the honest read; a weekly sum would dwarf the daily view's scale for no insight.
    static func weeklyStepAverages(_ days: [StepPoint], calendar: Calendar = .current) -> [StepPoint] {
        guard !days.isEmpty else { return [] }
        var buckets: [Date: (sum: Double, n: Int)] = [:]
        for p in days {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: p.date)?.start else { continue }
            let b = buckets[week] ?? (0, 0)
            buckets[week] = (b.sum + p.steps, b.n + 1)
        }
        return buckets.map { StepPoint(date: $0.key, steps: $0.value.n > 0 ? $0.value.sum / Double($0.value.n) : 0) }
            .sorted { $0.date < $1.date }
    }

    /// The card's one-line answer: the trailing 7-day average, and its % change vs the 7 days
    /// before (nil until both windows hold data — a delta against nothing is a made-up number).
    static func stepsHeadline(_ days: [StepPoint]) -> (avg: Double, deltaPct: Double?) {
        let sorted = days.sorted { $0.date < $1.date }
        let current = Array(sorted.suffix(7))
        let prior = Array(sorted.dropLast(7).suffix(7))
        let avg = current.isEmpty ? 0 : current.map(\.steps).reduce(0, +) / Double(current.count)
        guard prior.count >= 4, current.count >= 4 else { return (avg, nil) }   // ≥ half a window each
        let priorAvg = prior.map(\.steps).reduce(0, +) / Double(prior.count)
        guard priorAvg > 0 else { return (avg, nil) }
        return (avg, (avg - priorAvg) / priorAvg * 100)
    }
}

// MARK: - This week (the stat strip every endurance app leads with)

/// Four numbers, one card: distance · time · sessions · climb, each against last week. The
/// Strava-progress beat in the house voice — big tabular numerals, quiet deltas, no judgement
/// (a down week after a race is a good week; the chip states the fact and stops).
struct WeekStatStrip: View {
    let now: TrendsEssentials.WeekStat
    let prev: TrendsEssentials.WeekStat
    var distanceUnit: DistanceUnit = .auto

    private var imperial: Bool { distanceUnit.resolved() == .imperial }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("THIS WEEK")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                Spacer(minLength: 0)
                Text("vs last week")
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            HStack(alignment: .top, spacing: 0) {
                column(value: Formatters.distance(meters: now.distanceM, unit: distanceUnit),
                       label: "distance", delta: pctDelta(now.distanceM, prev.distanceM))
                column(value: Formatters.duration(s: now.durationS),
                       label: "time", delta: pctDelta(now.durationS, prev.durationS))
                column(value: "\(now.sessions)",
                       label: "sessions", delta: countDelta(now.sessions, prev.sessions))
                column(value: climbText,
                       label: "climb", delta: pctDelta(now.elevationM, prev.elevationM))
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week")
        .accessibilityValue("\(Formatters.distance(meters: now.distanceM, unit: distanceUnit)), "
                            + "\(Formatters.duration(s: now.durationS)), \(now.sessions) sessions, "
                            + "\(climbText) of climb, versus last week")
    }

    private var climbText: String {
        let v = imperial ? now.elevationM * 3.28084 : now.elevationM
        return "\(Formatters.compact(v)) \(imperial ? "ft" : "m")"
    }

    private func column(value: String, label: String, delta: String?) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
            Text(delta ?? " ")
                .font(.rounded(10, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .opacity(delta == nil ? 0 : 1)   // keeps the four columns level
        }
        .frame(maxWidth: .infinity)
    }

    /// "↑12%" — only when last week actually holds data; a percentage against zero is noise.
    private func pctDelta(_ now: Double, _ prev: Double) -> String? {
        guard prev > 0 else { return nil }
        let pct = (now - prev) / prev * 100
        guard abs(pct) >= 1 else { return nil }
        return "\(pct >= 0 ? "↑" : "↓")\(Int(abs(pct).rounded()))%"
    }

    /// "+2" — session counts are tiny integers; a percentage would shout about nothing.
    private func countDelta(_ now: Int, _ prev: Int) -> String? {
        guard prev > 0, now != prev else { return nil }
        return now > prev ? "+\(now - prev)" : "−\(prev - now)"
    }
}

// MARK: - Daily movement (steps — the ambient base under the training)

/// Steps from Apple Health, the Oura/Bevel daily-movement read: bars by day (weekly averages on
/// the wide ranges), the trailing 7-day average as the one-line answer, today in iridescence.
/// Training is the peaks; this is the floor it stands on.
struct StepsCard: View {
    /// Daily points, oldest → newest. nil = still loading; empty = Health has nothing for us.
    let days: [TrendsEssentials.StepPoint]?
    let isDaily: Bool
    let windowPhrase: String
    var animate: Bool = true
    /// The Oura tap-through — non-nil adds the quiet chevron and makes the card open its detail.
    var onOpen: (() -> Void)? = nil

    @State private var scrub = ChartScrubState()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("DAILY MOVEMENT")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                Spacer(minLength: 0)
                if onOpen != nil {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            if let days, !days.isEmpty {
                let headline = TrendsEssentials.stepsHeadline(days)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Formatters.compact(headline.avg))
                        .font(.display(30, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Text("steps / day")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    Spacer(minLength: Theme.Space.sm)
                    if let pct = headline.deltaPct, abs(pct) >= 1 {
                        Text("\(pct >= 0 ? "↑" : "↓")\(Int(abs(pct).rounded()))%")
                            .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                // Caption must match what chart() actually plots: it only collapses to weekly
                // averages above 35 points, so the 1M range (≈30 daily bars) is still by-day.
                Text(isDaily ? "7-day average · steps by day, from Apple Health"
                             : days.count <= 35 ? "7-day average · steps by day, \(windowPhrase)"
                             : "7-day average · daily steps averaged per week, \(windowPhrase)")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .padding(.bottom, Theme.Space.xs)
                chart(days)
            } else if days == nil {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    .frame(height: 120)
                    .redacted(reason: .placeholder)
            } else {
                Text("Steps appear here once Apple Health is connected.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.vertical, Theme.Space.lg)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        // Tap-through anywhere off the plot (the chart's scrub gesture wins inside it).
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily steps")
        .accessibilityValue(days.flatMap { d -> String? in
            guard !d.isEmpty else { return nil }
            return "about \(Int(TrendsEssentials.stepsHeadline(d).avg)) steps a day"
        } ?? "not available")
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
        .accessibilityHint(onOpen != nil ? "Shows the full trend" : "")
    }

    private func chart(_ days: [TrendsEssentials.StepPoint]) -> some View {
        // The Week range receives 14 days (the headline's delta needs the prior week) but plots
        // only the trailing 7; wide ranges plot weekly averages so a year never becomes 365 slivers.
        let visible = isDaily ? Array(days.suffix(7)) : days
        let pts = visible.count <= 35 ? visible : TrendsEssentials.weeklyStepAverages(visible)
        let unit: Calendar.Component = visible.count <= 35 ? .day : .weekOfYear
        let maxV = pts.map(\.steps).max() ?? 0
        let last = pts.last?.date
        let width: CGFloat = switch pts.count {
        case ...8: 18
        case ...16: 10
        case ...35: 6
        default: 4
        }
        return Chart {
            ForEach(pts) { p in
                BarMark(x: .value("Date", p.date, unit: unit),
                        y: .value("Steps", animate ? p.steps : 0),
                        width: .fixed(width))
                    .foregroundStyle(p.date == last ? AnyShapeStyle(IridescentMaterial())
                                                    : AnyShapeStyle(Theme.ink.opacity(0.55)))
                    .cornerRadius(2)
            }
            if let sel = scrub.pinned, let p = pts.first(where: { $0.date == sel }) {
                TrendScrub.mark(at: sel, unit: unit,
                                value: "\(Formatters.compact(p.steps)) steps",
                                label: unit == .day ? TrendScrub.dayLabel(sel) : TrendScrub.weekLabel(sel))
            }
        }
        .chartXSelection(value: $scrub.selection(dates: pts.map(\.date)))
        // Steps read against a ~20k ceiling — an ordinary 8k day sits mid-chart instead of
        // towering to full height. The axis still grows past it whenever the data does.
        .chartYScale(domain: 0...max(20_000, maxV * 1.18))
        .chartXAxis {
            if unit == .day {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
            } else {
                // Weekly averages: month+day up to ~3 months, month-only beyond — month-only
                // forces a ≥5-week stride (longer than any month), so no "Jun · Jun".
                AxisMarks(values: .stride(by: .weekOfYear, count: max(pts.count > 14 ? 5 : 2, Int((Double(pts.count) / 5).rounded(.up))))) { _ in
                    AxisValueLabel(format: pts.count > 14 ? .dateTime.month(.abbreviated)
                                                          : .dateTime.month(.abbreviated).day())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                let isZero = (value.as(Double.self) ?? 1) == 0
                AxisGridLine().foregroundStyle(isZero ? Theme.inkTertiary.opacity(0.35) : Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(Formatters.compact(v)) }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
            }
        }
        .frame(height: 150)
    }
}

// MARK: - Totals (this month · this year · all time)

/// The odometer: the three windows athletes quote. Distance leads (the number they'd tell a
/// friend), sessions and hours sit under it in caption voice.
struct TrendTotalsCard: View {
    let totals: TrendsEssentials.Totals
    var distanceUnit: DistanceUnit = .auto

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("TOTALS")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            HStack(alignment: .top, spacing: 0) {
                column("This month", totals.month)
                column("This year", totals.year)
                column("All time", totals.lifetime)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Totals")
        .accessibilityValue("This month \(Formatters.distance(meters: totals.month.distanceM, unit: distanceUnit)), "
                            + "this year \(Formatters.distance(meters: totals.year.distanceM, unit: distanceUnit)), "
                            + "all time \(Formatters.distance(meters: totals.lifetime.distanceM, unit: distanceUnit))")
    }

    private func column(_ label: String, _ b: TrendsEssentials.TotalsBucket) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
            Text(Formatters.distance(meters: b.distanceM, unit: distanceUnit))
                .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text("\(b.sessions) session\(b.sessions == 1 ? "" : "s") · \(hoursText(b.durationS))")
                .font(.rounded(10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hoursText(_ s: Double) -> String {
        let h = s / 3600
        return h >= 10 ? "\(Int(h.rounded()))h" : String(format: "%.1fh", h)
    }
}
