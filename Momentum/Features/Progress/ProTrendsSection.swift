import SwiftUI
import Charts

/// The premium analytics layer for the Trends tab. Self-contained: hand it the workouts + units
/// and it renders an at-a-glance vitals strip, the full Fitness & Freshness PMC (CTL·ATL + the
/// diverging Form strip), and cadence/climb/efficiency — each in its own honest form (dots vs a
/// target zone, a mountain silhouette, a line against the efficient zone) and its domain ink,
/// iridescence staying the earned "you are here" pop. Everything here is data the app already
/// captures; gate the whole section with `.proLocked(.advancedAnalytics)` at the call site.
struct ProTrendsSection: View {
    let workouts: [Workout]
    var distanceUnit: DistanceUnit = .auto
    /// Only compute when the analytics are unlocked — a free user sees a blurred teaser, so there's
    /// no reason to fault every run's samples and run the trend pipeline for them.
    var pro: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var model: Model?

    private var imperial: Bool { distanceUnit.resolved() == .imperial }

    /// The whole section's data, computed once off the render path (the engines fault thousands of
    /// GPS/HR samples and were previously re-run inside `body` on every re-render).
    struct Model {
        var metrics: [TrendAnalytics.SummaryMetric]
        var ffPoints: [TrendAnalytics.DayPoint]
        var cadence: [TrendAnalytics.WeekValue]
        var climbMeters: [TrendAnalytics.WeekValue]
        var efficiency: [TrendAnalytics.WeekValue]

        static func build(_ workouts: [Workout]) -> Model {
            // Decoupling is the heaviest walk here (every run's full HR+GPS series) — compute it
            // once and share it with `summary()` instead of paying it twice per build.
            let efficiency = TrendAnalytics.recentDecoupling(workouts: workouts)
            return Model(metrics: TrendAnalytics.summary(workouts: workouts, decoupling: efficiency),
                         ffPoints: TrendAnalytics.fitnessFreshness(workouts: workouts),
                         cadence: TrendAnalytics.weeklyCadence(workouts: workouts).filter { $0.value > 0 },
                         climbMeters: TrendAnalytics.weeklyClimb(workouts: workouts),
                         efficiency: efficiency)
        }
    }

    /// Session cache: the whole Trends branch — and this view's `@State` — is destroyed on every
    /// segment flip, and `.task(id:)` re-fires on every tab visit, so an unguarded build re-ran
    /// the full pipeline per visit. The analytics are deterministic from the workout array, so
    /// count is a complete key; pure value types only (never cache SwiftData refs).
    @MainActor private static var modelCache: (count: Int, model: Model)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let model {
                TrendVitalsStrip(metrics: model.metrics, imperial: imperial)
                FitnessFreshnessCard(points: model.ffPoints, animate: appeared)
                    .id("ffCard")   // --progress-scroll-ff sim-verification anchor
                cadenceCard(model)
                climbCard(model)
                efficiencyCard(model)
            } else {
                // Placeholder while the pipeline resolves (one hop) or when locked (never computed).
                skeleton
            }
        }
        // Compute once per data change, off the first frame. Skip entirely when locked.
        .task(id: pro ? workouts.count : -1) {
            guard pro else { return }
            if let cached = Self.modelCache, cached.count == workouts.count {
                if model == nil { model = cached.model }   // instant remount after a segment flip
                return
            }
            if model == nil { await Task.yield() }   // let the first frame paint the skeleton
            let built = Model.build(workouts)
            Self.modelCache = (workouts.count, built)
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

    // MARK: Cadence · Climb · Efficiency (weekly)

    /// Cadence — a dot plot: weekly samples read against the 174–186 target zone (180 is the
    /// classic efficient turnover). Monochrome — mechanics differentiate by form, not colour.
    private func cadenceCard(_ model: Model) -> some View {
        TrendChartCard(title: "Cadence", subtitle: "Weekly average · the band is the efficient zone",
                       series: model.cadence, animate: appeared,
                       reference: 180, referenceLabel: "180",
                       explainer: MetricExplainers.cadence, tint: Theme.ink,
                       form: .dots, band: 174...186, bandLabel: "TARGET",
                       headline: true, headlineUnit: "spm",
                       format: { "\(Int($0.rounded()))" })
    }

    /// Climb — a mountain silhouette: sharp linear peaks on a zero baseline, terrain rather than
    /// a smoothed trend.
    private func climbCard(_ model: Model) -> some View {
        let series = model.climbMeters.map { TrendAnalytics.WeekValue(weekStart: $0.weekStart,
                                                                      value: imperial ? $0.value * 3.28084 : $0.value) }
        return TrendChartCard(title: "Climb", subtitle: "Elevation gained per week · your training terrain",
                              series: series, animate: appeared,
                              explainer: MetricExplainers.climb, tint: Theme.ink,
                              form: .mountain,
                              headline: true, headlineUnit: imperial ? "ft" : "m",
                              format: { Formatters.compact($0) })
    }

    /// Aerobic efficiency — HR drift in the ice ink, read against the mint "efficient" zone
    /// (under 5% drift on steady runs is the aerobically-fit read).
    private func efficiencyCard(_ model: Model) -> some View {
        TrendChartCard(title: "Aerobic efficiency",
                       subtitle: "Heart-rate drift on steady runs · lower is fitter",
                       series: model.efficiency, animate: appeared, lowerIsBetter: true,
                       explainer: MetricExplainers.aerobicEfficiency, tint: MetricColor.pace,
                       form: .line, band: 0...5, bandLabel: "EFFICIENT", bandTint: MetricColor.fresh,
                       headline: true,
                       format: { String(format: "%.1f%%", $0) })
    }
}

// MARK: - Vitals strip (the at-a-glance grid)

/// A two-column grid of compact metric tiles — current value, a factual trend chip, and a
/// sparkline. The dense, scannable "everything at once" read; each tile's full chart lives below.
struct TrendVitalsStrip: View {
    let metrics: [TrendAnalytics.SummaryMetric]
    var imperial: Bool = false

    private let columns = [GridItem(.flexible(), spacing: Theme.Space.sm),
                           GridItem(.flexible(), spacing: Theme.Space.sm)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Space.sm) {
            ForEach(metrics) { m in VitalTile(metric: m, imperial: imperial) }
        }
    }
}

private struct VitalTile: View {
    let metric: TrendAnalytics.SummaryMetric
    var imperial: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(label).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                    .foregroundStyle(Theme.inkTertiary)
                Spacer(minLength: 4)
                if metric.available, let t = metric.trendPct, abs(t) >= 1 { trendChip(t) }
            }
            if metric.available {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(valueText).font(.display(26, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let u = unit {
                        Text(u).font(.rounded(Theme.FontSize.label, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                Sparkline(values: metric.spark, tint: MetricColor.of(metric.kind))
                    .frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("—").font(.display(26, weight: .heavy)).foregroundStyle(Theme.inkTertiary)
                Text(emptyHint).font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary).lineLimit(1).minimumScaleFactor(0.7)
                    .frame(height: 26, alignment: .leading)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(metric.available ? "\(valueText) \(unit ?? "")" : "no data yet")
    }

    /// The trend chip: a good-direction move reads green, the wrong direction reads red, in a soft
    /// tinted pill so it's legible off the card (the pale iridescent it replaced washed out here).
    private func trendChip(_ t: Double) -> some View {
        // Up is green, down is red — read the arrow, read the trend, no second-guessing.
        let tint = t >= 0 ? MetricColor.positive : MetricColor.negative
        // Clamp the shown magnitude — a cold-start ramp (fitness climbing from zero) produces
        // arithmetically-huge but meaningless percentages; "99%+" reads honestly without shouting.
        let mag = Int(abs(t).rounded())
        return HStack(spacing: 1) {
            Image(systemName: t >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .black))
            Text(mag > 99 ? "99%+" : "\(mag)%").font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var label: String {
        switch metric.kind {
        case .fitness: "FITNESS"
        case .form: "FORM"
        case .load: "LOAD"
        case .cadence: "CADENCE"
        case .climb: "CLIMB"
        case .efficiency: "EFFICIENCY"
        }
    }

    private var valueText: String {
        switch metric.kind {
        case .fitness, .load: "\(Int(metric.value.rounded()))"
        case .form: "\(metric.value >= 0 ? "+" : "")\(Int(metric.value.rounded()))"
        case .cadence: "\(Int(metric.value.rounded()))"
        case .climb: Formatters.compact(imperial ? metric.value * 3.28084 : metric.value)
        case .efficiency: String(format: "%.1f", metric.value)
        }
    }

    private var unit: String? {
        switch metric.kind {
        case .cadence: "spm"
        case .climb: imperial ? "ft" : "m"
        case .efficiency: "%"
        default: nil
        }
    }

    private var emptyHint: String {
        switch metric.kind {
        case .cadence: "needs cadence"
        case .efficiency: "needs HR runs"
        default: "keep training"
        }
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
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.inkTertiary)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(series.last.map { "latest \(format($0.value))" } ?? subtitle)
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
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: max(2, series.count / 5))) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.inkTertiary)
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
