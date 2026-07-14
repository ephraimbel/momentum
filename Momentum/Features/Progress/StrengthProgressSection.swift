import SwiftUI
import Charts

/// The premium strength-progression layer for the Trends tab. Self-contained: hand it the workouts
/// + weight unit and it renders a lift vitals strip, an interactive per-lift e1RM curve, weekly
/// volume, and a muscle-balance read. Same chart language as `ProTrendsSection`; gate the whole
/// thing with `.proLocked(.advancedAnalytics)`. Renders nothing when there's no strength history.
struct StrengthProgressSection: View {
    let workouts: [Workout]
    var weightUnit: WeightUnit = .kg
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedLift: String?
    @State private var appeared = false

    private var lifts: [String] { StrengthTrends.topLifts(in: workouts) }
    private var hasStrength: Bool { workouts.contains { $0.type.isStrengthStyle && $0.strength != nil } }

    var body: some View {
        if hasStrength {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                LiftVitalsStrip(metrics: StrengthTrends.liftSummary(in: workouts), weightUnit: weightUnit)
                if !lifts.isEmpty { liftProgressionCard }
                volumeCard
                muscleBalanceCard
            }
            .onAppear {
                if selectedLift == nil { selectedLift = lifts.first }
                if reduceMotion { appeared = true }
                else { withAnimation(.easeOut(duration: 0.6)) { appeared = true } }
            }
        }
    }

    // MARK: Lift progression (the interactive hero)

    private var liftProgressionCard: some View {
        let lift = selectedLift ?? lifts.first ?? ""
        let series = ExerciseTrends.e1RMSeries(exerciseName: lift, in: workouts)
        let gain = ExerciseTrends.gainPercent(series)
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lift progression").font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Estimated 1‑rep max · your working top set").font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                if series.count >= 2, abs(gain) >= 0.5 { gainBadge(gain) }
                MetricInfoButton(explainer: MetricExplainers.liftProgression)
                    .padding(.leading, Theme.Space.sm)
            }
            // Lift picker — the athlete's staples, most-trained first.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(lifts, id: \.self) { name in liftChip(name) }
                }
            }
            e1rmChart(series)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)))
    }

    private func liftChip(_ name: String) -> some View {
        let on = (selectedLift ?? lifts.first) == name
        return Button {
            withAnimation(.smooth(duration: 0.3)) { selectedLift = name }
        } label: {
            Text(name)
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                .foregroundStyle(on ? Theme.background : Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(on ? Theme.ink : Theme.surface)
                    .overlay(Capsule().stroke(on ? Theme.ink : Theme.hairline)))
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

    private func e1rmChart(_ series: [ExerciseTrends.Point]) -> some View {
        let disp: (Double) -> Double = { weightUnit == .lb ? $0 * Formatters.lbPerKg : $0 }
        let vals = series.map { disp($0.e1RM) }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let pad = max((hi - lo) * 0.2, 2)
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
                            .foregroundStyle(LinearGradient(colors: [MetricColor.chart.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", p.date), y: .value("e1RM", appeared ? disp(p.e1RM) : lo))
                            .foregroundStyle(MetricColor.chart).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    if let p = series.last, appeared {
                        PointMark(x: .value("Date", p.date), y: .value("e1RM", disp(p.e1RM)))
                            .foregroundStyle(IridescentMaterial()).symbolSize(90)
                            .annotation(position: .top, spacing: 6) {
                                Text(Formatters.weight(kg: p.e1RM, unit: weightUnit))
                                    .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.surface).overlay(Capsule().stroke(Theme.hairline)))
                            }
                    }
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
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
                .frame(height: 170)
            }
        }
    }

    // MARK: Weekly volume

    private var volumeCard: some View {
        let raw = StrengthTrends.weeklyVolume(in: workouts)
        let series = raw.map { TrendAnalytics.WeekValue(weekStart: $0.weekStart,
                                                        value: weightUnit == .lb ? $0.value * Formatters.lbPerKg : $0.value) }
        let unit = weightUnit == .lb ? "lb" : "kg"
        return TrendChartCard(title: "Training volume",
                              subtitle: "Weight moved per week · working sets · \(unit)",
                              series: series, animate: appeared, filled: true,
                              explainer: MetricExplainers.trainingVolume, tint: MetricColor.chart,
                              format: { Formatters.compact($0) })
    }

    // MARK: Muscle balance

    private var muscleBalanceCard: some View {
        let loads = StrengthTrends.muscleBalance(in: workouts)
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
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)))
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
                              : AnyShapeStyle(LinearGradient(colors: [MetricColor.chart, MetricColor.chart.opacity(0.55)],
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
            Sparkline(values: metric.spark, tint: MetricColor.chart)
                .frame(height: 24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)))
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
