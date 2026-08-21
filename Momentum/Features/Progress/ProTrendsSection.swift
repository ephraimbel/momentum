import SwiftUI
import Charts

/// The Fitness & Freshness curve — the one deep-analytics chart that earned its place in the
/// 2026-07-22 Trends redesign. Self-contained: hand it the workouts and it computes the PMC
/// (CTL·ATL + the diverging Form strip) off the render path and renders the card.
///
/// What this section USED to also hold, and why it doesn't: the vitals sparkline strip (resting
/// HR/HRV/sleep live on the Health page — duplicating them here was the wall's worst offender),
/// and the cadence/climb/efficiency trio (exotic mechanics that read as noise next to the numbers
/// endurance athletes actually track; `TrendAnalytics` still computes them, tests intact, if a
/// dedicated mechanics surface ever earns them back). `TrendChartCard`/`Sparkline` below are kept
/// — the Strength section and the Health page's VitalsBoard render through them.
struct ProTrendsSection: View {
    let workouts: [Workout]
    var distanceUnit: DistanceUnit = .auto
    /// Only compute when the analytics are unlocked — a free user sees a blurred teaser, so there's
    /// no reason to fault every run's samples and run the trend pipeline for them.
    var pro: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var model: Model?

    /// The section's data, computed once off the render path (the F&F pipeline walks every
    /// workout's load history; it was previously re-run inside `body` on every re-render).
    /// Slimmed with the 2026-07-22 redesign: only the PMC points — the retired cards' pipelines
    /// (summary/cadence/climb/decoupling) no longer run at all, which also makes this build
    /// several times cheaper.
    struct Model {
        var ffPoints: [TrendAnalytics.DayPoint]

        static func build(_ workouts: [Workout]) -> Model {
            Model(ffPoints: TrendAnalytics.fitnessFreshness(workouts: workouts))
        }
    }

    /// Session cache: the whole Trends branch — and this view's `@State` — is destroyed on every
    /// segment flip, and `.task(id:)` re-fires on every tab visit, so an unguarded build re-ran
    /// the full pipeline per visit. The analytics are deterministic from the workout array, so
    /// a content signature + day is the key (count alone missed equal-count edits — delete one,
    /// log another: the curve replayed pre-edit data — and the F&F pipeline bakes "today" into
    /// the curve's anchor, so a rest stretch must not replay yesterday's form as current);
    /// pure value types only (never SwiftData refs).
    @MainActor private static var modelCache: (key: String, model: Model)?

    private var cacheKey: String {
        "\(workouts.contentSignature)-\(Int(Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let model {
                FitnessFreshnessCard(points: model.ffPoints, animate: appeared)
                    .id("ffCard")   // --progress-scroll-ff sim-verification anchor
            } else {
                // Placeholder while the pipeline resolves (one hop) or when locked (never computed).
                skeleton
            }
        }
        // Compute once per data change, off the first frame. Skip entirely when locked.
        .task(id: pro ? cacheKey : "locked") {
            guard pro else { return }
            let key = cacheKey
            if let cached = Self.modelCache, cached.key == key {
                if model == nil { model = cached.model }   // instant remount after a segment flip
                return
            }
            if model == nil { await Task.yield() }   // let the first frame paint the skeleton
            let built = Model.build(workouts)
            Self.modelCache = (key, built)
            model = built
        }
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.easeOut(duration: 0.6)) { appeared = true } }
        }
    }

    private var skeleton: some View {
        VStack(spacing: Theme.Space.md) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    .frame(height: 120)
            }
        }
        .redacted(reason: .placeholder)
    }

}


/// A tiny normalized line for a tile — tinted stroke over a soft same-hue fill, the latest point
/// an iridescent dot. The tint carries the metric's identity so each tile reads at a glance.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = Theme.ink

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if pts.count > 1 {
                // Soft area under the line, in the metric's hue.
                Path { p in
                    p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                    for pt in pts { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in
                    p.move(to: pts[0])
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(IridescentMaterial()).frame(width: 5, height: 5)
                        .position(last)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let v = values.filter { $0.isFinite }
        guard v.count > 1, let lo = v.min(), let hi = v.max() else { return [] }
        let span = max(hi - lo, 0.0001)
        let dx = size.width / CGFloat(v.count - 1)
        let pad: CGFloat = 3
        return v.enumerated().map { i, val in
            CGPoint(x: CGFloat(i) * dx,
                    y: pad + (1 - CGFloat((val - lo) / span)) * (size.height - 2 * pad))
        }
    }
}

// MARK: - Fitness & Freshness (the marquee PMC chart)

/// Fitness (CTL, rising slow), Fatigue (ATL, spikier), and Form (TSB = the gap). The premium
/// endurance-analytics view, momentum-styled: fitness as a filled ink line, fatigue as a quiet
/// dashed line, today in iridescence, and a plain-words Form read in the header.
struct FitnessFreshnessCard: View {
    let points: [TrendAnalytics.DayPoint]
    var animate: Bool = true

    @State private var scrub = ChartScrubState()   // tap-to-inspect any day (shared Trends mechanic)

    private var current: TrendAnalytics.DayPoint? { points.last }

    /// Start the plot where fitness first accrues — for an athlete with only a few weeks of
    /// history, showing months of leading flat-zero reads as a broken chart. A continuous
    /// athlete has no leading zero, so this is a no-op for them.
    private var plotted: [TrendAnalytics.DayPoint] {
        // No day has accrued real load yet (a brand-new athlete) → plot NOTHING, so the card shows its
        // "a few weeks of training will draw your curve" state instead of a flat-zero line reading as a
        // real (empty) fitness curve. A continuous athlete finds an onset and is unaffected.
        guard let onset = points.firstIndex(where: { $0.ctl > 1 || $0.atl > 1 }) else { return [] }
        return Array(points[max(0, onset - 3)...])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            if plotted.count < 8 {
                notEnough
            } else {
                chart
                legend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fitness and freshness")
        .accessibilityValue(current.map { "Fitness \(Int($0.ctl)), form \(Int($0.tsb)), \(FitnessFreshness.formLabel($0.tsb))" } ?? "not enough data")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Fitness & freshness").font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Your training's long game").font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            if let c = current {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(c.tsb >= 0 ? "+" : "")\(Int(c.tsb.rounded()))")
                        .font(.display(24, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(IridescentMaterial())
                    Text(FitnessFreshness.formLabel(c.tsb).uppercased())
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.8).foregroundStyle(Theme.inkSecondary)
                }
            }
            MetricInfoButton(explainer: MetricExplainers.fitnessFreshness)
                .padding(.leading, Theme.Space.sm)
        }
    }

    private var chart: some View {
        // The domain must clear FATIGUE too — ATL (7-day) spikes above CTL after a hard block, and
        // a CTL-only ceiling let the dashed fatigue line shoot off the top of the card. It must
        // also dip below zero for the Form bars (TSB goes negative when you're buried).
        let pts = plotted
        let maxY = max(pts.map(\.ctl).max() ?? 1, pts.map(\.atl).max() ?? 1)
        let minTSB = pts.map(\.tsb).min() ?? 0
        let floor = min(0, minTSB * 1.15)
        return Chart {
            // FORM as a thin diverging strip around the zero line — fresh days rise mint, buried
            // days dip peach (the sanctioned mint+peach pairing; position carries the sign). The
            // full PMC read in one panel: the line is what you've built, the strip is what it cost.
            ForEach(pts) { p in
                BarMark(x: .value("Day", p.date), y: .value("Form", animate ? p.tsb : 0),
                        width: .fixed(1.5))
                    .foregroundStyle((p.tsb >= 0 ? MetricColor.fresh : MetricColor.load).opacity(0.38))
            }
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Theme.inkTertiary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(pts) { p in
                AreaMark(x: .value("Day", p.date), y: .value("Fitness", animate ? p.ctl : 0))
                    .foregroundStyle(LinearGradient(colors: [MetricColor.fitness.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            ForEach(pts) { p in
                LineMark(x: .value("Day", p.date), y: .value("Fatigue", animate ? p.atl : 0),
                         series: .value("s", "atl"))
                    .foregroundStyle(Theme.inkTertiary)   // fatigue is the muted "cost" line — grey + dashed
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .interpolationMethod(.monotone)
            }
            ForEach(pts) { p in
                LineMark(x: .value("Day", p.date), y: .value("Fitness", animate ? p.ctl : 0),
                         series: .value("s", "ctl"))
                    .foregroundStyle(MetricColor.fitness)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let c = current, animate {
                PointMark(x: .value("Day", c.date), y: .value("Fitness", c.ctl))
                    .foregroundStyle(IridescentMaterial()).symbolSize(90)
            }
            if let sel = scrub.pinned, let p = pts.first(where: { $0.date == sel }) {
                TrendScrub.mark(at: sel,
                                value: "Fitness \(Int(p.ctl.rounded())) · Form \(p.tsb >= 0 ? "+" : "")\(Int(p.tsb.rounded()))",
                                label: sel.formatted(.dateTime.month(.abbreviated).day()))
            }
        }
        .chartXSelection(value: $scrub.selection(dates: pts.map(\.date)))
        .chartYScale(domain: floor...max(1, maxY * 1.12))
        // Half a day's padding each side: the daily form bars are 1.5 pt slivers drawn at exact
        // instants, and without a padded domain the first and last bar half-clipped at the frame.
        // Month-boundary labels stay — this is the one continuous daily chart, and month starts
        // are the honest ruler for a PMC curve (marks are unit-less, so tick and mark geometry
        // agree by construction).
        .chartXScale(domain: TrendAxis.domain(for: pts.map(\.date), granularity: .daily))
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .font(TrendAxis.labelFont).foregroundStyle(Theme.inkTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(TrendAxis.labelFont).foregroundStyle(Theme.inkTertiary)
            }
        }
        .frame(height: 190)
    }

    private var legend: some View {
        HStack(spacing: Theme.Space.md) {
            legendItem("Fitness", MetricColor.fitness, dashed: false)
            legendItem("Fatigue", Theme.inkTertiary, dashed: true)
            // Form's dual swatch — mint above the line, peach below.
            HStack(spacing: 5) {
                HStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 1).fill(MetricColor.fresh.opacity(0.7)).frame(width: 5, height: 8)
                    RoundedRectangle(cornerRadius: 1).fill(MetricColor.load.opacity(0.7)).frame(width: 5, height: 8)
                }
                Text("Form ±").font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            if let c = current {
                Text("Fitness \(Int(c.ctl.rounded()))")
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func legendItem(_ label: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 2.5)
                .opacity(dashed ? 0.6 : 1)
            Text(label).font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
        }
    }

    private var notEnough: some View {
        Text("A few weeks of training will draw your fitness curve here.")
            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center).multilineTextAlignment(.center)
    }
}

// MARK: - Generic weekly trend card (cadence / climb / efficiency)

/// A weekly single-series chart in the shared card language — but each metric picks its honest
/// FORM: `.line` for trends, `.bars` for magnitudes, `.dots` for samples against a target zone,
/// `.mountain` for terrain. Optional reference line, "good zone" band, and the Oura-style
/// big-number header (`headline`) so every card leads with its one-line answer.
struct TrendChartCard: View {
    enum ChartForm { case line, bars, dots, mountain }

    let title: String
    let subtitle: String
    let series: [TrendAnalytics.WeekValue]
    var animate: Bool = true
    var filled: Bool = false
    var lowerIsBetter: Bool = false
    var reference: Double? = nil
    var referenceLabel: String? = nil
    var explainer: MetricExplainer? = nil
    var tint: Color = Theme.ink
    var form: ChartForm = .line
    /// A "good zone" wash band (e.g. cadence 174–186, efficiency 0–5%) the marks read against.
    var band: ClosedRange<Double>? = nil
    var bandLabel: String? = nil
    var bandTint: Color? = nil
    /// Lead the card with the latest value in the display face + a direction-aware trend chip.
    var headline: Bool = false
    var headlineUnit: String? = nil
    /// The Oura tap-through — non-nil adds the quiet chevron and opens the metric's detail.
    var onOpen: (() -> Void)? = nil
    let format: (Double) -> String

    @State private var scrub = ChartScrubState()   // tap-to-inspect any week (shared Trends mechanic)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                if headline {
                    Text(title.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                        .foregroundStyle(Theme.inkTertiary)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                        Text(subtitle).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                if let explainer { MetricInfoButton(explainer: explainer) }
                if onOpen != nil {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            if headline {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(series.last.map { format($0.value) } ?? "—")
                        .font(.display(30, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if let headlineUnit {
                        Text(headlineUnit).font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    if let t = trendPct, abs(t) >= 1 { trendChip(t) }
                }
                Text(subtitle).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .padding(.bottom, Theme.Space.xs)
            }
            if series.count < 2 {
                Text("Not enough data yet — keep logging.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                chart
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)))
        // Tap-through anywhere off the plot (the chart's scrub gesture wins inside it).
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(series.last.map { "latest \(format($0.value))" } ?? subtitle)
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
        .accessibilityHint(onOpen != nil ? "Shows the full trend" : "")
    }

    /// Latest week vs the average of the prior (up to) three — the headline's factual chip.
    private var trendPct: Double? {
        guard series.count >= 3, let last = series.last?.value else { return nil }
        let prior = series.dropLast().suffix(3).map(\.value)
        let avg = prior.reduce(0, +) / Double(prior.count)
        guard abs(avg) > 0.0001 else { return nil }
        return (last - avg) / abs(avg) * 100
    }

    /// A good-direction move earns the legible green; the other direction stays quiet ink —
    /// no-shame, the zone/reference on the chart carries the judgment.
    private func trendChip(_ t: Double) -> some View {
        let good = lowerIsBetter ? t < 0 : t >= 0
        return HStack(spacing: 1) {
            Image(systemName: t >= 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 9, weight: .black))
            Text("\(min(99, Int(abs(t).rounded())))%").font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(good ? MetricColor.positive : Theme.inkSecondary)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(good ? MetricColor.positive.opacity(0.12) : Theme.hairline.opacity(0.6)))
    }

    /// Bar width steps with the on-screen count so bars never touch (mirrors the Trends charts).
    private var barWidth: CGFloat {
        switch series.count {
        case ...8: 18
        case ...14: 10
        default: 6
        }
    }

    private var chart: some View {
        let vals = series.map(\.value)
        var lo = vals.min() ?? 0
        var hi = vals.max() ?? 1
        if let reference { lo = min(lo, reference); hi = max(hi, reference) }
        if let band { lo = min(lo, band.lowerBound); hi = max(hi, band.upperBound) }
        let pad = max((hi - lo) * 0.18, 1)
        // Magnitude forms sit on a true zero baseline; trend forms zoom to the data.
        let floor = (form == .bars || form == .mountain) ? 0 : lo - pad
        let last = series.last?.weekStart
        return Chart {
            if let band {
                RectangleMark(yStart: .value("Zone low", band.lowerBound),
                              yEnd: .value("Zone high", band.upperBound))
                    // An ink band needs less presence than a pastel one to read equally quiet.
                    .foregroundStyle((bandTint ?? tint).opacity(bandTint == nil ? 0.06 : 0.12))
                    .annotation(position: .overlay, alignment: .topTrailing) {
                        if let bandLabel {
                            Text(bandLabel).font(.system(size: 8, weight: .bold)).tracking(0.8)
                                .foregroundStyle(Theme.inkTertiary).padding(3)
                        }
                    }
            }
            if let reference {
                RuleMark(y: .value("Reference", reference))
                    .foregroundStyle(Theme.inkTertiary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        if let referenceLabel {
                            Text(referenceLabel).font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
            }
            ForEach(series) { wk in
                switch form {
                case .line:
                    if filled {
                        // Anchor the fill to the chart's floor, not the default y=0 baseline — otherwise
                        // the gradient spills past the card whenever the domain doesn't start at zero.
                        AreaMark(x: .value("Week", wk.weekStart),
                                 yStart: .value("floor", lo - pad),
                                 yEnd: .value("v", animate ? wk.value : lo - pad))
                            .foregroundStyle(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Week", wk.weekStart), y: .value("v", animate ? wk.value : lo))
                        .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                case .mountain:
                    // Terrain, not a trend — sharp linear peaks, a heavy-at-the-ridge gradient, no dots.
                    AreaMark(x: .value("Week", wk.weekStart),
                             yStart: .value("floor", 0),
                             yEnd: .value("v", animate ? wk.value : 0))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.linear)
                    LineMark(x: .value("Week", wk.weekStart), y: .value("v", animate ? wk.value : 0))
                        .foregroundStyle(tint.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .bevel))
                        .interpolationMethod(.linear)
                case .bars:
                    BarMark(x: .value("Week", wk.weekStart), y: .value("v", animate ? wk.value : 0),
                            width: .fixed(barWidth))
                        .foregroundStyle(wk.weekStart == last ? AnyShapeStyle(IridescentMaterial())
                                                              : AnyShapeStyle(tint.opacity(0.85)))
                        .cornerRadius(3)
                case .dots:
                    PointMark(x: .value("Week", wk.weekStart), y: .value("v", animate ? wk.value : lo))
                        .foregroundStyle(wk.weekStart == last ? AnyShapeStyle(IridescentMaterial())
                                                              : AnyShapeStyle(tint.opacity(0.85)))
                        .symbolSize(wk.weekStart == last ? 90 : 40)
                }
            }
            if form == .line || form == .mountain, let wk = series.last, animate {
                PointMark(x: .value("Week", wk.weekStart), y: .value("v", wk.value))
                    .foregroundStyle(IridescentMaterial()).symbolSize(form == .mountain ? 60 : 90)
                    .annotation(position: .top, spacing: 6) {
                        // The pill only where there's no big-number header saying the same thing.
                        if !headline, scrub.pinned == nil { valuePill(format(wk.value)) }
                    }
            }
            if let sel = scrub.pinned, let wk = series.first(where: { $0.weekStart == sel }) {
                TrendScrub.mark(at: sel, value: format(wk.value), label: TrendScrub.weekLabel(sel))
            }
        }
        .chartXSelection(value: $scrub.selection(dates: series.map(\.weekStart)))
        .chartYScale(domain: floor...(hi + pad))
        // TrendAxis law: these weekly series roll from "now" (an arbitrary weekday), and the old
        // `.stride(by: .weekOfYear)` ticks landed on CALENDAR week starts — every label named a
        // date with no bar on it, offset 0–6 days. Labels now sit on the bars' own dates.
        .chartXScale(domain: TrendAxis.domain(for: series.map(\.weekStart), granularity: .weekly))
        .chartXAxis { TrendAxis.marks(for: series.map(\.weekStart), granularity: .weekly) }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(TrendAxis.labelFont).foregroundStyle(Theme.inkTertiary)
            }
        }
        .frame(height: 160)
    }

    private func valuePill(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.surface).overlay(Capsule().stroke(Theme.hairline)))
    }
}
