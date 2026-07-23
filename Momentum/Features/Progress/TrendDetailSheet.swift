import SwiftUI
import Charts

/// The Oura-style tap-through for a Trends card (2026-07-23): the card answers in one line, the
/// tap answers in full. A bigger chart over LONGER windows (up to a year — beyond the page
/// picker's 6M), the window's summary stats, and the metric's plain-words explanation beneath —
/// the same `MetricExplainer` prose the ⓘ shows, so science never forks. ONE shared sheet for
/// every metric with a value-over-time shape; tap-through depth reads identically everywhere
/// (the `ChartScrub` principle, one level up).
struct TrendDetail: Identifiable {
    enum Form { case bars, line }
    enum Stat: CaseIterable { case average, best, total, latest }

    let id: String
    let title: String                          // "Weekly distance"
    let unit: String                           // "mi" · "steps" · "lb" — small, after the numeral
    var form: Form = .bars
    /// Pace-style metrics: "best" is the minimum, and a falling line is the good direction.
    var lowerIsBetter = false
    var stats: [Stat] = [.average, .best, .total]
    /// The y-axis top never drops below this. Steps read against a ~20k ceiling so an ordinary
    /// 8k day sits mid-chart instead of towering to full height; the axis still grows past it
    /// whenever the data does. Leave at the default for data-hugging metrics.
    var minimumYTop: Double = 1
    /// Line-form metrics whose absolute zero is meaningless (HRV, wrist temp): the domain hugs
    /// the data (and the band) instead of anchoring at zero — a 36.5 °C line on a 0-anchored
    /// axis is an unreadable sliver.
    var hugsY = false
    /// Domain ink for the marks (the Health pages speak in domain colors, §6). nil keeps the
    /// Trends monochrome: ink marks, iridescent current bar/point. With a tint the current
    /// element renders in FULL tint instead — iridescence stays earned-only, and a vital
    /// holding steady isn't an achievement.
    var tint: Color? = nil
    /// The personal band (mean ± 1 SD) rendered as a quiet ribbon behind the line — the
    /// "your own normal" reference the Health hub is built on.
    var band: (lower: Double, upper: Double)? = nil
    /// The ribbon's wash color (defaults to the tint at low opacity when nil).
    var bandTint: Color? = nil
    /// Caption after the band range, e.g. "mean ± 1 SD · 30 days".
    var bandNote: String? = nil
    var explainer: MetricExplainer?
    /// Value → display numeral (no unit — the unit renders separately, quiet).
    var format: (Double) -> String
    /// Points for a `weeksBack` window, oldest → newest. Async so Health-backed series can fetch;
    /// zero-value points are honest gaps and render as such.
    var series: (Int) async -> [Point]

    struct Point: Identifiable, Equatable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    /// Calendar-week means of a daily series — for metrics whose long windows would otherwise
    /// plot a year as 365 slivers (sleep, steps). Averages, not sums: the value keeps its
    /// per-day meaning at every range.
    static func weeklyAverages(_ pts: [Point], calendar: Calendar = .current) -> [Point] {
        var buckets: [Date: (total: Double, count: Int)] = [:]
        for p in pts where p.value > 0 {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: p.date)?.start else { continue }
            buckets[week, default: (0, 0)].total += p.value
            buckets[week]!.count += 1
        }
        return buckets.map { Point(date: $0.key, value: $0.value.total / Double($0.value.count)) }
            .sorted { $0.date < $1.date }
    }
}

struct TrendDetailSheet: View {
    let detail: TrendDetail
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The detail's own windows — deliberately LONGER than the page picker. The card shows the
    /// recent story; the tap is where the year lives.
    private enum Range: String, CaseIterable, Identifiable {
        case month = "1M", quarter = "3M", half = "6M", year = "1Y"
        var id: Self { self }
        var weeks: Int {
            switch self {
            case .month: 5
            case .quarter: 13
            case .half: 26
            case .year: 52
            }
        }
        var phrase: String {
            switch self {
            case .month: "past month"
            case .quarter: "past 3 months"
            case .half: "past 6 months"
            case .year: "past year"
            }
        }
    }

    @State private var range: Range = .quarter
    @State private var points: [TrendDetail.Point]?
    @State private var drawn = false
    @State private var scrub = ChartScrubState()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    hero.reveal(0)
                    rangePicker.reveal(0.04)
                    chartArea.reveal(0.08)
                    if let points, !points.isEmpty { statsRow(points).reveal(0.12) }
                    if let band = detail.band { bandRow(band).reveal(0.14) }
                    if let explainer = detail.explainer { prose(explainer).reveal(0.16) }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .navigationTitle(detail.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).foregroundStyle(Theme.ink)
                }
            }
            // Refetch per window; the old curve holds until the new one lands (no skeleton flash),
            // then the numerals roll and the chart redraws — a range flip reads as one movement.
            .task(id: range) {
                let pts = await detail.series(range.weeks)
                withAnimation(reduceMotion ? nil : Motion.standard) {
                    points = pts
                    scrub = .init()   // a pinned week from the old window means nothing here
                }
            }
            .onAppear {
                if reduceMotion { drawn = true }
                else { withAnimation(.easeOut(duration: 0.8)) { drawn = true } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Hero — the window's one-line answer

    private var hero: some View {
        let latest = points?.last(where: { $0.value > 0 })?.value
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(latest.map(detail.format) ?? "—")
                    .font(.display(34, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(detail.unit)
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            Text("Latest · \(range.phrase)")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .contentTransition(.opacity)
        }
        .animation(Motion.standard, value: points)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.title)
        .accessibilityValue("latest \(latest.map(detail.format) ?? "no data") \(detail.unit), \(range.phrase)")
    }

    // MARK: Range picker — the page picker's exact capsule language

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(Range.allCases) { r in
                let on = range == r
                Button {
                    Haptics.selection()
                    withAnimation(Motion.standard) { range = r }
                } label: {
                    Text(r.rawValue)
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? Theme.background : Theme.inkSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background { if on { Capsule().fill(Theme.ink) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(r.phrase)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.surface))
    }

    // MARK: The big chart

    @ViewBuilder private var chartArea: some View {
        if let points {
            if points.contains(where: { $0.value > 0 }) {
                chart(points)
            } else {
                Text("Nothing in this window yet.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                .frame(height: 240)
                .redacted(reason: .placeholder)
        }
    }

    /// A daily series (the steps card's month window) plots per-day; everything else per-week.
    /// Inferred from point spacing so callers never have to declare granularity per range.
    private static func isDaily(_ pts: [TrendDetail.Point]) -> Bool {
        guard pts.count > 1, let first = pts.first, let lastPt = pts.last else { return false }
        let span = lastPt.date.timeIntervalSince(first.date)
        return span / Double(pts.count - 1) < 3 * 86_400
    }

    private func chart(_ pts: [TrendDetail.Point]) -> some View {
        let maxV = pts.map(\.value).max() ?? 0
        let plotted = detail.form == .line ? pts.filter { $0.value > 0 } : pts
        let daily = Self.isDaily(plotted)
        let unit: Calendar.Component = daily ? .day : .weekOfYear
        let last = plotted.last?.date
        let barWidth: CGFloat = switch plotted.count {
        case ...8: 18
        case ...16: 10
        case ...30: 7
        default: 4
        }
        // Weekly axes stride like the page's `weekAxis`: month+day up to ~3 months, month-only
        // beyond. Month-only forces a ≥5-week stride (longer than any month), so a month can
        // never label twice ("Jun · Jun").
        let monthOnly = plotted.count > 14
        let axisStride = max(monthOnly ? 5 : 2, Int((Double(plotted.count) / 5).rounded(.up)))
        return Chart {
            if let band = detail.band, let first = plotted.first?.date, let lastDate = last {
                RectangleMark(xStart: .value("Date", first, unit: unit),
                              xEnd: .value("Date", lastDate, unit: unit),
                              yStart: .value("Band low", band.lower),
                              yEnd: .value("Band high", band.upper))
                    .foregroundStyle((detail.bandTint ?? detail.tint ?? Theme.ink).opacity(0.2))
                    .cornerRadius(4)
            }
            ForEach(plotted) { p in
                switch detail.form {
                case .bars:
                    BarMark(x: .value("Date", p.date, unit: unit),
                            y: .value(detail.title, drawn ? p.value : 0),
                            width: .fixed(barWidth))
                        .foregroundStyle(barStyle(isCurrent: p.date == last))
                        .cornerRadius(2)
                case .line:
                    LineMark(x: .value("Date", p.date, unit: unit),
                             y: .value(detail.title, drawn ? p.value : maxV))
                        .foregroundStyle(detail.tint ?? Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                    if p.date == last {
                        PointMark(x: .value("Date", p.date, unit: unit),
                                  y: .value(detail.title, drawn ? p.value : maxV))
                            .symbolSize(46)
                            .foregroundStyle(detail.tint.map(AnyShapeStyle.init)
                                             ?? AnyShapeStyle(IridescentMaterial()))
                    }
                }
            }
            if let sel = scrub.pinned, let p = plotted.first(where: { $0.date == sel }) {
                TrendScrub.mark(at: sel, unit: unit,
                                value: "\(detail.format(p.value)) \(detail.unit)",
                                label: daily ? TrendScrub.dayLabel(sel) : TrendScrub.weekLabel(sel))
            }
        }
        .chartXSelection(value: $scrub.selection(dates: plotted.map(\.date)))
        .chartYScale(domain: detail.form == .line && (detail.lowerIsBetter || detail.hugsY)
                     ? yDomainHugging(plotted) : 0...max(detail.minimumYTop, maxV * 1.15))
        .chartXAxis {
            if daily, plotted.count > 60 {
                // Long daily series (a season of vitals, a year of nights): month labels on
                // month starts — day-level labels at this width clip at the right edge.
                AxisMarks(values: .stride(by: .month, count: plotted.count > 200 ? 3 : 1)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
            } else if daily {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
            } else {
                AxisMarks(values: .stride(by: .weekOfYear, count: axisStride)) { _ in
                    AxisValueLabel(format: monthOnly ? .dateTime.month(.abbreviated)
                                                     : .dateTime.month(.abbreviated).day())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                let isZero = (value.as(Double.self) ?? 1) == 0
                AxisGridLine().foregroundStyle(isZero ? Theme.inkTertiary.opacity(0.35) : Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(detail.format(v)) }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
            }
        }
        .frame(height: 240)
    }

    /// The zero-free domain: pad the real span (and the personal band, when there is one) so the
    /// line breathes — pace, HRV, wrist temp all die as slivers on a 0-anchored axis.
    private func yDomainHugging(_ pts: [TrendDetail.Point]) -> ClosedRange<Double> {
        var vs = pts.map(\.value).filter { $0 > 0 }
        if let band = detail.band { vs.append(contentsOf: [band.lower, band.upper]) }
        guard let lo = vs.min(), let hi = vs.max(), lo < hi else {
            let v = vs.first ?? 1
            return v * 0.9...v * 1.1
        }
        let pad = (hi - lo) * 0.2
        return (lo - pad)...(hi + pad)
    }

    /// Bars: monochrome ink with the iridescent current bar — unless the metric speaks a domain
    /// tint (Health), where the current bar is simply full-strength tint.
    private func barStyle(isCurrent: Bool) -> AnyShapeStyle {
        if let tint = detail.tint {
            return AnyShapeStyle(tint.opacity(isCurrent ? 1 : 0.5))
        }
        return isCurrent ? AnyShapeStyle(IridescentMaterial())
                         : AnyShapeStyle(Theme.ink.opacity(0.75))
    }

    // MARK: Stats — the window in three numbers

    private func statsRow(_ pts: [TrendDetail.Point]) -> some View {
        let nonzero = pts.map(\.value).filter { $0 > 0 }
        return HStack(alignment: .top, spacing: 0) {
            ForEach(detail.stats, id: \.self) { stat in
                let value: Double? = switch stat {
                case .average: nonzero.isEmpty ? nil : nonzero.reduce(0, +) / Double(nonzero.count)
                case .best: detail.lowerIsBetter ? nonzero.min() : nonzero.max()
                case .total: nonzero.isEmpty ? nil : nonzero.reduce(0, +)
                case .latest: nonzero.last
                }
                VStack(spacing: 2) {
                    Text(value.map(detail.format) ?? "—")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    Text(label(stat))
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .animation(Motion.standard, value: pts)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Summary")
        .accessibilityValue(detail.stats.map { stat in
            let value: Double? = switch stat {
            case .average: nonzero.isEmpty ? nil : nonzero.reduce(0, +) / Double(nonzero.count)
            case .best: detail.lowerIsBetter ? nonzero.min() : nonzero.max()
            case .total: nonzero.isEmpty ? nil : nonzero.reduce(0, +)
            case .latest: nonzero.last
            }
            return "\(label(stat)) \(value.map(detail.format) ?? "none") \(detail.unit)"
        }.joined(separator: ", "))
    }

    /// "YOUR NORMAL 56–74 ms · mean ± 1 SD · 30 days" — the ribbon's legend, in the Health
    /// hub's exact words: the band is the athlete's own norm, never a population number.
    private func bandRow(_ band: (lower: Double, upper: Double)) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text("YOUR NORMAL")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                .foregroundStyle(Theme.inkTertiary)
            Text("\(detail.format(band.lower))–\(detail.format(band.upper)) \(detail.unit)")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 0)
            if let note = detail.bandNote {
                Text(note)
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your normal range")
        .accessibilityValue("\(detail.format(band.lower)) to \(detail.format(band.upper)) \(detail.unit)")
    }

    private func label(_ s: TrendDetail.Stat) -> String {
        switch s {
        case .average: "average"
        case .best: "best"
        case .total: "total"
        case .latest: "latest"
        }
    }

    // MARK: The science, beneath the data — the ⓘ's exact prose, so it never forks

    private func prose(_ e: MetricExplainer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let formula = e.formula {
                Text(formula)
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Theme.surface).overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)))
            }
            ForEach(Array(e.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.heading.uppercased())
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Theme.inkTertiary)
                    Text(section.body)
                        .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let footnote = e.footnote {
                Text(footnote)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.top, Theme.Space.sm)
    }
}
