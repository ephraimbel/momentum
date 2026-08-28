import SwiftUI
import SwiftData
import Charts

/// Per-lift progression (PRD §4.8, §13.10) — the estimated-1RM curve over time plus a session
/// readout. Reached from the Lift Progression card's tap-through (re-linked 2026-07-23).
struct ExerciseDetailView: View {
    let exerciseName: String
    var weightUnit: WeightUnit = .default()

    @Query private var workouts: [Workout]
    // Hot-path rule: the full workout×exercise×set walk runs ONCE per data change in `.task(id:)`
    // below — as a computed var it re-ran ~8× per body evaluation (headline, chart, domain,
    // stats, recent), each pass faulting every strength relationship.
    @State private var series: [ExerciseTrends.Point] = []
    @State private var heaviest: String?
    @State private var resolved = false

    private var best: Double { series.map(\.e1RM).max() ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if !resolved {
                    Color.clear.frame(height: 1)   // one quiet frame while the walk resolves
                } else if series.isEmpty {
                    emptyState
                } else {
                    headline
                    chartCard.proLocked(.advancedAnalytics)
                    statsCard
                    recentCard
                }
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle(exerciseName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(exerciseName)-\(workouts.contentSignature)") {
            series = ExerciseTrends.e1RMSeries(exerciseName: exerciseName, in: workouts)
            heaviest = Self.heaviestSet(named: exerciseName, in: workouts, unit: weightUnit)
            resolved = true
        }
    }

    // MARK: Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BEST ESTIMATED 1RM").font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.4).foregroundStyle(Theme.inkTertiary)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(Formatters.weight(kg: best, unit: weightUnit))
                    .font(.display(40, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                let gain = ExerciseTrends.gainPercent(series)
                if gain != 0 {
                    Text("\(gain > 0 ? "+" : "")\(Int(gain.rounded()))%")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Chart (Pro)

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("e1RM OVER TIME").font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.4).foregroundStyle(Theme.inkTertiary)
            // A STEP curve (strength moves in jumps, session to session — a smoothed line implies
            // strength you never had between sessions), a soft ink floor, a tick per session,
            // and the best session wearing the earned iridescence. Same grammar as the
            // progression rows' sparklines.
            let bestPoint = series.max { $0.e1RM < $1.e1RM }
            Chart {
                ForEach(series, id: \.date) { point in
                    AreaMark(x: .value("Date", point.date),
                             yStart: .value("floor", yDomain.lowerBound),
                             yEnd: .value("e1RM", disp(point.e1RM)))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", point.date), y: .value("e1RM", disp(point.e1RM)))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Theme.ink)
                    PointMark(x: .value("Date", point.date), y: .value("e1RM", disp(point.e1RM)))
                        .symbolSize(22).foregroundStyle(Theme.ink)
                }
                if let bestPoint {
                    PointMark(x: .value("Date", bestPoint.date), y: .value("e1RM", disp(bestPoint.e1RM)))
                        .symbolSize(110).foregroundStyle(IridescentMaterial())
                        .annotation(position: .top, spacing: 6) {
                            Text("BEST").font(.system(size: 8, weight: .black)).tracking(0.8).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(IridescentMaterial()).opacity(0.55))
                        }
                }
            }
            .chartYScale(domain: yDomain)
            // Was the stock unstyled axis — the only chart on the tab ignoring the shared look.
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
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
            .frame(height: 200)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    private var yDomain: ClosedRange<Double> {
        let values = series.map { disp($0.e1RM) }
        let lo = (values.min() ?? 0) * 0.9, hi = (values.max() ?? 1) * 1.05
        return lo < hi ? lo...hi : 0...max(1, hi)
    }

    // MARK: Stats + recent

    private var statsCard: some View {
        HStack(spacing: Theme.Space.xl) {
            stat("\(series.count)", "Sessions")
            stat(lastSessionLabel, "Last")
            if let heaviest { stat(heaviest, "Heaviest") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("RECENT SESSIONS").font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.4).foregroundStyle(Theme.inkTertiary)
            let recent = Array(series.suffix(6))
            ForEach(Array(recent.enumerated().reversed()), id: \.element.date) { i, point in
                if i < recent.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                HStack(spacing: Theme.Space.sm) {
                    Text(point.date.formatted(.dateTime.month().day()))
                        .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    Spacer()
                    // The move since the session before it — the honest per-session receipt.
                    if i > 0 {
                        let delta = point.e1RM - recent[i - 1].e1RM
                        if abs(delta) >= 0.5 {
                            Text("\(delta > 0 ? "+" : "−")\(Formatters.weight(kg: abs(delta), unit: weightUnit))")
                                .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                                .foregroundStyle(delta > 0 ? MetricColor.positive : Theme.inkTertiary)
                        }
                    }
                    Text(Formatters.weight(kg: point.e1RM, unit: weightUnit))
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                        .frame(width: 76, alignment: .trailing)
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            BrandMark(size: 64)
            Text("No history yet").font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Log \(exerciseName) a few times and your strength curve appears here.")
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, Theme.Space.xxl)
    }

    // MARK: Helpers

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var lastSessionLabel: String {
        series.last.map { $0.date.formatted(.dateTime.month().day()) } ?? "—"
    }

    /// Heaviest single working set ever logged for this lift (across all sessions).
    private static func heaviestSet(named exerciseName: String, in workouts: [Workout],
                                    unit: WeightUnit) -> String? {
        var top: (kg: Double, reps: Int)?
        for w in workouts {
            for row in (w.strength?.exercises ?? []) where row.exercise?.name == exerciseName {
                for set in row.sets where set.isComplete && set.type == .working {
                    guard let kg = set.weightKg, let reps = set.reps else { continue }
                    if kg > (top?.kg ?? 0) { top = (kg, reps) }
                }
            }
        }
        guard let top else { return nil }
        return "\(Formatters.weight(kg: top.kg, unit: unit))×\(top.reps)"
    }

    private func disp(_ kg: Double) -> Double { weightUnit == .lb ? kg * Formatters.lbPerKg : kg }

    private var card: some View {
        ZStack {
            Color.clear.raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }
}
