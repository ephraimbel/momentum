import SwiftUI
import SwiftData
import Charts

/// Progress — the coaching brain (PRD §4.7, §4.8). A training-status hero (ACWR), an AI coach card
/// that says how you're trending and how to tweak the plan, beautifully animated trend charts, a
/// consistency heatmap, PR shelves, and lifetime totals.
struct ProgressScreen: View {
    @Query private var workouts: [Workout]
    @State private var animateCharts = false

    private var weightUnit: WeightUnit { .default() }
    private var distanceUnit: DistanceUnit { .auto }
    private var stats: ProfileStats { ProfileStats(workouts: workouts) }
    private var insights: ProgressInsights { ProgressInsights(workouts: workouts) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text("Progress").font(.display(32, weight: .black)).foregroundStyle(Theme.ink)
                    .padding(.top, Theme.Space.sm)
                statusHero(insights)
                coachCard(insights)
                loadChart(insights)
                distanceChart(insights)
                heatmap(stats)
                if !stats.strengthPRs.isEmpty { prShelf(stats) }
                totals(stats)
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { animateCharts = true } }
    }

    // MARK: Status hero

    private func statusHero(_ insights: ProgressInsights) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("TRAINING STATUS").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            Text(insights.status.rawValue).font(.display(30, weight: .black)).foregroundStyle(Theme.ink)
            acwrGauge(insights.acwr)
            Text(gaugeCaption(insights)).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    private func acwrGauge(_ acwr: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                // Optimal band (ACWR 0.8–1.3 on a 0–2 scale).
                Capsule().fill(IridescentMaterial()).opacity(0.55)
                    .frame(width: w * 0.25).offset(x: w * 0.40)
                Circle().fill(Theme.ink).frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                    .offset(x: max(0, min(w - 16, w * min(1, acwr / 2) - 8)))
            }
        }
        .frame(height: 16)
    }

    private func gaugeCaption(_ insights: ProgressInsights) -> String {
        guard insights.acwr > 0 else { return "Build a couple of weeks and your load balance shows here." }
        return "Load balance \(String(format: "%.2f", insights.acwr)) · sweet spot is 0.8–1.3"
    }

    // MARK: AI coach card

    private func coachCard(_ insights: ProgressInsights) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "sparkles"); Text("COACH").tracking(1.5)
            }
            .font(.rounded(Theme.FontSize.label, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            Text(ProgressNarrator.coach(insights, streak: stats.currentStreak))
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .bold))
                Text(ProgressNarrator.action(insights.recommendation)).font(.rounded(Theme.FontSize.caption, weight: .bold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
            .background { Capsule().fill(IridescentMaterial()).opacity(0.3); Capsule().stroke(Theme.hairline) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    // MARK: Charts

    private func loadChart(_ insights: ProgressInsights) -> some View {
        chartSection("Weekly training load", subtitle: "Last 8 weeks") {
            Chart(insights.weeks) { wk in
                BarMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                        y: .value("Load", animateCharts ? wk.load : 0))
                    .foregroundStyle(IridescentMaterial())
                    .cornerRadius(5)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 150)
        }
    }

    private func distanceChart(_ insights: ProgressInsights) -> some View {
        let unit = distanceUnit.resolved() == .imperial ? "mi" : "km"
        func disp(_ m: Double) -> Double { distanceUnit.resolved() == .imperial ? m / Formatters.metersPerMile : m / 1000 }
        return chartSection("Weekly distance", subtitle: "In \(unit)") {
            Chart(insights.weeks) { wk in
                AreaMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                         y: .value("Distance", animateCharts ? disp(wk.distanceM) : 0))
                    .foregroundStyle(IridescentMaterial()).opacity(0.25)
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Week", wk.weekStart, unit: .weekOfYear),
                         y: .value("Distance", animateCharts ? disp(wk.distanceM) : 0))
                    .foregroundStyle(Theme.ink).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 150)
        }
    }

    private func chartSection<C: View>(_ title: String, subtitle: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                Text(subtitle).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    // MARK: Heatmap / PRs / totals (from ProfileStats)

    private func heatmap(_ stats: ProfileStats) -> some View {
        let today = StreakCalculator.localDay(Date())
        let weeks = 16
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Consistency")
            HStack(spacing: 3) {
                ForEach(0..<weeks, id: \.self) { col in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { row in
                            let day = today - ((weeks - 1 - col) * 7) - (6 - row)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(stats.countingDays.contains(day) ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.hairline))
                                .frame(width: 13, height: 13)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.lg)
        .background(card)
    }

    private func prShelf(_ stats: ProfileStats) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("Personal records")
            ForEach(stats.strengthPRs, id: \.name) { pr in
                HStack {
                    Text(pr.name).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(Formatters.weight(kg: pr.e1RMKg, unit: weightUnit)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    private func totals(_ stats: ProfileStats) -> some View {
        HStack(spacing: Theme.Space.xl) {
            stat("\(stats.totalWorkouts)", "Workouts")
            stat(Formatters.distance(meters: stats.totalDistanceM, unit: distanceUnit), "Distance")
            stat(Formatters.duration(s: stats.totalDurationS), "Time")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(card)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
    }
}
