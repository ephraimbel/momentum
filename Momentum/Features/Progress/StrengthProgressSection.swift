import SwiftUI
import Charts

/// The premium strength-progression layer for the Trends tab. Self-contained: hand it the workouts
/// + weight unit and it renders a lift vitals strip, an interactive per-lift e1RM curve, weekly
/// volume, and a muscle-balance read. Same chart language as `ProTrendsSection`; gate the whole
/// thing with `.proLocked(.advancedAnalytics)`. Renders nothing when there's no strength history.
struct StrengthProgressSection: View {
    let workouts: [Workout]
    var weightUnit: WeightUnit = .kg
    /// The wheel's window — the Trends range's activation days, so the wheel, the body figure
    /// and the progression rows all read the same slice of training.
    var days: Int = 30
    /// Only compute when unlocked — a free user sees a blurred teaser, so skip the full walk of every
    /// workout × exercise × set (previously re-run several times per render, uncached).
    var pro: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedLift: String?
    @State private var appeared = false
    @State private var model: Model?
    @State private var scrubE1RM = ChartScrubState()   // tap-to-inspect (shared Trends mechanic)
    /// The Oura tap-throughs (2026-07-23): volume opens the shared TrendDetailSheet; the lift
    /// progression card opens the full per-exercise history (`ExerciseDetailView` — built long
    /// ago, reachable at last).
    @State private var volumeDetail: TrendDetail?
    @State private var liftDetail: LiftDetailItem?
    @State private var showAllLifts = false
    @State private var showLoadDetail = false

    struct LiftDetailItem: Identifiable {
        let name: String
        var id: String { name }
    }

    private var hasStrength: Bool { workouts.contains { $0.type.isStrengthStyle && $0.strength != nil } }

    /// The whole section's data, computed once off the render path. `topLifts`/`liftSummary`/
    /// `weeklyVolume`/`muscleBalance` each walked every workout×exercise×set and were re-run on
    /// every `body` pass; the per-lift e1RM curves are precomputed for the staple lifts (≤4).
    struct Model {
        var lifts: [String]
        var summary: [StrengthTrends.LiftMetric]
        var seriesByLift: [String: [ExerciseTrends.Point]]
        var volumeKg: [TrendAnalytics.WeekValue]
        var balance: [StrengthTrends.MuscleLoad]
        /// The wheel (six regions, wheel order) and the progression rows (all lifts, staples first).
        var regions: [StrengthTrends.RegionLoad] = []
        var progression: [StrengthTrends.LiftMetric] = []

        static func build(_ workouts: [Workout], days: Int = 30) -> Model {
            let lifts = StrengthTrends.topLifts(in: workouts)
            var series: [String: [ExerciseTrends.Point]] = [:]
            for lift in lifts { series[lift] = ExerciseTrends.e1RMSeries(exerciseName: lift, in: workouts) }
            return Model(lifts: lifts,
                         summary: StrengthTrends.liftSummary(in: workouts),
                         seriesByLift: series,
                         volumeKg: StrengthTrends.weeklyVolume(in: workouts),
                         balance: StrengthTrends.muscleBalance(in: workouts),
                         regions: StrengthTrends.regionLoads(in: workouts, days: days),
                         progression: StrengthTrends.progression(in: workouts, limit: 40))
        }
    }

    /// Session cache — same rationale as ProTrendsSection: segment flips destroy `@State` and
    /// `.task(id:)` re-fires per tab visit, so an unguarded build re-walked every set per visit.
    /// Deterministic from the workout array + day; keyed on a content signature (count alone
    /// missed equal-count edits) plus a day stamp (weekly volume/balance window off "now" — a
    /// resident app must not replay yesterday's week); pure value types only.
    @MainActor private static var modelCache: (key: String, model: Model)?

    private var cacheKey: String {
        "\(workouts.contentSignature)-\(days)-\(Int(Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate))"
    }

    var body: some View {
        if hasStrength {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                if let model {
                    // The Bevel-structured chapter (2026-08-28): the muscle-load wheel, the
                    // progression rows, then weekly tonnage. The wheel shares the body figure's
                    // window and muscle weighting, so the figure above lights where the wheel leads.
                    MuscleLoadCard(loads: model.regions, weightUnit: weightUnit, days: days, animate: appeared,
                                   onOpen: { showLoadDetail = true })
                    if !model.progression.isEmpty {
                        StrengthProgressionCard(rows: Array(model.progression.prefix(5)), weightUnit: weightUnit,
                                                animate: appeared,
                                                onOpenAll: { showAllLifts = true },
                                                onOpen: { liftDetail = LiftDetailItem(name: $0.name) })
                    }
                    volumeCard(model)
                } else {
                    skeleton
                }
            }
            .task(id: pro ? cacheKey : "locked") {
                guard pro else { return }
                let key = cacheKey
                if let cached = Self.modelCache, cached.key == key {
                    if model == nil { model = cached.model }   // instant remount after a segment flip
                    if selectedLift == nil { selectedLift = cached.model.lifts.first }
                    return
                }
                if model == nil { await Task.yield() }   // paint the skeleton first
                let built = Model.build(workouts, days: days)
                Self.modelCache = (key, built)
                if selectedLift == nil { selectedLift = built.lifts.first }
                model = built
            }
            .onAppear {
                if reduceMotion { appeared = true }
                else { withAnimation(.easeOut(duration: 0.6)) { appeared = true } }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--progress-open-muscle-load") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { showLoadDetail = true }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-open-lift") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        if let first = model?.progression.first { liftDetail = LiftDetailItem(name: first.name) }
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--progress-open-volume") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { volumeDetail = volumeDetailPayload }
                }
                #endif
            }
            .sheet(item: $volumeDetail) { TrendDetailSheet(detail: $0) }
            .sheet(isPresented: $showLoadDetail) {
                NavigationStack {
                    MuscleLoadDetailView(workouts: workouts, weightUnit: weightUnit, initialDays: days)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showLoadDetail = false }.fontWeight(.semibold).foregroundStyle(Theme.ink)
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showAllLifts) {
                NavigationStack {
                    StrengthProgressionListView(rows: model?.progression ?? [], weightUnit: weightUnit) { m in
                        showAllLifts = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { liftDetail = LiftDetailItem(name: m.name) }
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showAllLifts = false }.fontWeight(.semibold).foregroundStyle(Theme.ink)
                        }
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            // The per-lift deep dive — full e1RM history, heaviest sets, the whole story.
            .sheet(item: $liftDetail) { lift in
                NavigationStack {
                    ExerciseDetailView(exerciseName: lift.name, weightUnit: weightUnit)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { liftDetail = nil }.fontWeight(.semibold).foregroundStyle(Theme.ink)
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var skeleton: some View {
        VStack(spacing: Theme.Space.md) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface).frame(height: 120)
            }
        }
        .redacted(reason: .placeholder)
    }

    // MARK: Lift progression (the interactive hero)

    private func liftProgressionCard(_ model: Model) -> some View {
        let lifts = model.lifts
        let lift = selectedLift ?? lifts.first ?? ""
        let series = model.seriesByLift[lift] ?? []
        let gain = ExerciseTrends.gainPercent(series)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("LIFT PROGRESSION").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
                Spacer(minLength: Theme.Space.sm)
                MetricInfoButton(explainer: MetricExplainers.liftProgression)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            // The headline answers for the selected lift — it re-reads as you flip chips.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(series.last.map { Formatters.weight(kg: $0.e1RM, unit: weightUnit) } ?? "—")
                    .font(.display(30, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("e1RM").font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                Spacer(minLength: Theme.Space.sm)
                if series.count >= 2, abs(gain) >= 0.5 { gainBadge(gain) }
            }
            Text("Estimated 1‑rep max · your working top set")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .padding(.bottom, Theme.Space.xs)
            // Lift picker — the athlete's staples, most-trained first.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(lifts, id: \.self) { name in liftChip(name, selected: lift) }
                }
            }
            e1rmChart(series)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        // Tap-through to the selected lift's full history (every set, the PR line, the story).
        // The lift chips and the ⓘ keep their own taps; the plot keeps its scrub; everywhere
        // else on the card opens the detail.
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onTapGesture { if !lift.isEmpty { liftDetail = LiftDetailItem(name: lift) } }
        .accessibilityHint("Shows the full history for \(lift)")
    }

    private func liftChip(_ name: String, selected: String) -> some View {
        let on = selected == name
        return Button {
            withAnimation(.smooth(duration: 0.3)) { selectedLift = name }
        } label: {
            Text(name)
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                .foregroundStyle(on ? .white : Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(on ? Theme.purple : Theme.surface)
                    .overlay(Capsule().stroke(on ? Theme.purple : Theme.hairline)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func gainBadge(_ gain: Double) -> some View {
        HStack(spacing: 2) {
            Image(systemName: gain >= 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 10, weight: .black))
            Text("\(abs(gain) >= 1 ? "\(Int(abs(gain).rounded()))" : String(format: "%.1f", abs(gain)))%")
                .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(gain >= 0 ? MetricColor.positive : MetricColor.negative)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill((gain >= 0 ? MetricColor.positive : MetricColor.negative).opacity(0.12)))
    }

    /// The e1RM curve as a STEP line — strength moves in discrete jumps, session to session, and
    /// the step form says so honestly (a smoothed curve implies strength you never had between
    /// sessions). Ink line, iridescent BEST marker: the strength family's monochrome look.
    private func e1rmChart(_ series: [ExerciseTrends.Point]) -> some View {
        let disp: (Double) -> Double = { weightUnit == .lb ? $0 * Formatters.lbPerKg : $0 }
        let vals = series.map { disp($0.e1RM) }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let pad = max((hi - lo) * 0.2, 2)
        let best = series.max(by: { $0.e1RM < $1.e1RM })
        let last = series.last?.date
        return Group {
            if series.count < 2 {
                Text("Log this lift again to see it climb.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                Chart {
                    ForEach(series, id: \.date) { p in
                        // Fill from the chart's own floor (not the default y=0, which sits far below
                        // this zoomed-in domain and spills the gradient outside the card).
                        AreaMark(x: .value("Date", p.date),
                                 yStart: .value("floor", lo - pad),
                                 yEnd: .value("e1RM", appeared ? disp(p.e1RM) : lo - pad))
                            .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.stepEnd)
                        LineMark(x: .value("Date", p.date), y: .value("e1RM", appeared ? disp(p.e1RM) : lo))
                            .foregroundStyle(Theme.ink).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.stepEnd)
                        // Each logged session is a visible tick on the steps.
                        PointMark(x: .value("Date", p.date), y: .value("e1RM", appeared ? disp(p.e1RM) : lo))
                            .foregroundStyle(Theme.ink).symbolSize(18)
                    }
                    // The all-time-in-view best earns the iridescent marker.
                    if let best, appeared {
                        PointMark(x: .value("Date", best.date), y: .value("e1RM", disp(best.e1RM)))
                            .foregroundStyle(IridescentMaterial()).symbolSize(90)
                            .annotation(position: best.date == last ? .topTrailing : .top, spacing: 5) {
                                if scrubE1RM.pinned == nil {
                                    Text("BEST").font(.system(size: 8, weight: .black)).tracking(0.8)
                                        .foregroundStyle(Theme.ink)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Capsule().fill(IridescentMaterial()).opacity(0.55))
                                }
                            }
                    }
                    if let sel = scrubE1RM.pinned, let p = series.first(where: { $0.date == sel }) {
                        TrendScrub.mark(at: sel,
                                        value: Formatters.weight(kg: p.e1RM, unit: weightUnit),
                                        label: sel.formatted(.dateTime.month(.abbreviated).day()))
                    }
                }
                .chartXSelection(value: $scrubE1RM.selection(dates: series.map(\.date)))
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartXAxis {
                    // Sessions land irregularly, so this step chart keeps a continuous time ruler
                    // (calendar ticks, not per-session labels) — marks are unit-less, so tick and
                    // step geometry agree. Typography joins the one TrendAxis rule.
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(TrendAxis.labelFont).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel().font(TrendAxis.labelFont).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .frame(height: 170)
            }
        }
    }

    // MARK: Weekly volume

    /// Weekly tonnage as ink bars — weight moved is a magnitude, and bars on a zero baseline are
    /// the honest form (the old line implied a continuous trend between training weeks).
    private func volumeCard(_ model: Model) -> some View {
        let raw = model.volumeKg
        let series = raw.map { TrendAnalytics.WeekValue(weekStart: $0.weekStart,
                                                        value: weightUnit == .lb ? $0.value * Formatters.lbPerKg : $0.value) }
        let unit = weightUnit == .lb ? "lb" : "kg"
        return TrendChartCard(title: "Training volume",
                              subtitle: "This week · weight moved across working sets",
                              series: series, animate: appeared,
                              explainer: MetricExplainers.trainingVolume, tint: Theme.ink,
                              form: .bars,
                              headline: true, headlineUnit: unit,
                              onOpen: { volumeDetail = volumeDetailPayload },
                              format: { Formatters.compact($0) })
    }

    /// The volume card's tap-through: the same weekly-volume pipeline over the sheet's own
    /// windows (up to a year), in the athlete's weight unit.
    private var volumeDetailPayload: TrendDetail {
        let toLb = weightUnit == .lb
        let workouts = self.workouts
        return TrendDetail(
            id: "strengthVolume", title: "Training volume", unit: toLb ? "lb" : "kg",
            stats: [.average, .best, .total],
            explainer: MetricExplainers.trainingVolume,
            format: { Formatters.compact(toLb ? $0 * Formatters.lbPerKg : $0) },
            series: { weeks in
                StrengthTrends.weeklyVolume(in: workouts, weeks: weeks)
                    .map { .init(date: $0.weekStart, value: $0.value) }
            })
    }

    // MARK: Muscle balance

    private func muscleBalanceCard(_ model: Model) -> some View {
        let loads = model.balance
        let maxSets = loads.map(\.sets).max() ?? 1
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Muscle balance").font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Working sets per muscle · last 4 weeks").font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: Theme.Space.sm)
                MetricInfoButton(explainer: MetricExplainers.muscleBalance)
            }
            if loads.isEmpty {
                Text("Log a few lifts to see where your volume lands.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                VStack(spacing: 7) {
                    ForEach(loads) { load in muscleRow(load, maxSets: maxSets) }
                }
                if let least = loads.last, loads.count >= 3 {
                    Text("Least worked: \(least.muscle.displayName). A little more would even you out.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func muscleRow(_ load: StrengthTrends.MuscleLoad, maxSets: Double) -> some View {
        let frac = maxSets > 0 ? load.sets / maxSets : 0
        let top = load.sets == maxSets
        return HStack(spacing: Theme.Space.sm) {
            Text(load.muscle.displayName)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                .frame(width: 78, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(top ? AnyShapeStyle(IridescentMaterial())
                              : AnyShapeStyle(LinearGradient(colors: [Theme.ink.opacity(0.85), Theme.ink.opacity(0.5)],
                                                             startPoint: .leading, endPoint: .trailing)))
                    .frame(width: max(load.sets > 0 ? 8 : 0, geo.size.width * appearedFrac(frac)))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)
            Text(load.sets == load.sets.rounded() ? "\(Int(load.sets))" : String(format: "%.1f", load.sets))
                .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(load.muscle.displayName)
        .accessibilityValue("\(Int(load.sets)) sets")
    }

    private func appearedFrac(_ frac: Double) -> CGFloat { appeared ? CGFloat(frac) : 0 }
}

// MARK: - Lift vitals strip

/// Top lifts as compact tiles — current e1RM, gain since first logged, and an e1RM sparkline.
struct LiftVitalsStrip: View {
    let metrics: [StrengthTrends.LiftMetric]
    var weightUnit: WeightUnit = .kg

    private let columns = [GridItem(.flexible(), spacing: Theme.Space.sm),
                           GridItem(.flexible(), spacing: Theme.Space.sm)]

    var body: some View {
        if !metrics.isEmpty {
            LazyVGrid(columns: columns, spacing: Theme.Space.sm) {
                ForEach(metrics) { m in LiftTile(metric: m, weightUnit: weightUnit) }
            }
        }
    }
}

private struct LiftTile: View {
    let metric: StrengthTrends.LiftMetric
    var weightUnit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(metric.name.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.inkTertiary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if metric.sessions >= 2, abs(metric.gainPct) >= 1 { gainChip(metric.gainPct) }
            }
            Text(Formatters.weight(kg: metric.currentE1RMKg, unit: weightUnit))
                .font(.display(22, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            // Strength stays monochrome — the lift sparklines draw in ink, not a domain tint.
            Sparkline(values: metric.spark, tint: Theme.ink.opacity(0.75))
                .frame(height: 24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.name)
        .accessibilityValue(Formatters.weight(kg: metric.currentE1RMKg, unit: weightUnit))
    }

    private func gainChip(_ g: Double) -> some View {
        HStack(spacing: 1) {
            Image(systemName: g >= 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 9, weight: .black))
            Text("\(min(99, Int(abs(g).rounded())))%").font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(g >= 0 ? MetricColor.positive : MetricColor.negative)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill((g >= 0 ? MetricColor.positive : MetricColor.negative).opacity(0.12)))
    }
}
