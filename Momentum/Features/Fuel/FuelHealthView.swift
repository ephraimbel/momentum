import SwiftUI
import SwiftData

/// The health-score analysis page (2026-08-15) — behind the Fuel masthead's gauge. One page that
/// answers "how healthy is the way I'm eating?": the day's score as a hero gauge, what moved it
/// (the engine's signed drivers, plain words), the last seven days as a quiet trend, and today's
/// foods ranked by their own scores — the healthiest and the most processed, named honestly.
///
/// Every number is the deterministic `HealthScore` engine, computed on-device from the nutrition
/// facts meals already carry — nothing here bills a call. Framing rules: the score judges the
/// FOOD, never the athlete; "Processed" is a description, not a verdict on a person; race fuel
/// reads low by design and the page says so. No diet, weight, or medical language.
struct FuelHealthView: View {
    /// Newest-first, bounded like the main page's journal window: the page reads today plus a
    /// 7-day trend — 400 rows ≈ two months at a heavy log rate, comfortably more than it walks.
    private static var recentMeals: FetchDescriptor<Meal> {
        var d = FetchDescriptor<Meal>(sortBy: [SortDescriptor(\Meal.eatenAt, order: .reverse)])
        d.fetchLimit = 400
        return d
    }
    @Query(FuelHealthView.recentMeals) private var meals: [Meal]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// One ranked food from today's journal.
    private struct RankedItem: Identifiable {
        let id = UUID()
        let name: String
        let portion: String
        let verdict: HealthScore.Verdict
    }

    private struct DayBar: Identifiable {
        let id: Date
        let label: String       // "M", "T", … today's letter renders emphasized
        let spokenDay: String   // "Monday" — VoiceOver never reads a bare letter
        let verdict: HealthScore.Verdict?
        let isToday: Bool
    }

    // Computed ONCE per data change (the page-load rule: no engine work in body) — decoding a
    // week of `itemsData` per render pass is exactly what the main page's caches exist to avoid.
    @State private var analysis: HealthScore.DayAnalysis?
    @State private var ranked: [RankedItem] = []
    @State private var week: [DayBar] = []
    @State private var weekAverage: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                hero.reveal(0)
                if let analysis, !analysis.verdict.drivers.isEmpty {
                    drivers(analysis).reveal(0.08)
                }
                if analysis?.sportsFuelPresent == true {
                    sportsFuelNote.reveal(0.12)
                }
                weekSection.reveal(0.16)
                if !ranked.isEmpty {
                    rankedSection.reveal(0.22)
                }
                footer.reveal(0.26)
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle("Health score")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: recompute)
        .onChange(of: meals.count) { recompute() }
        // Foregrounding after hours asleep: "today" is baked into the buckets, so re-judge at
        // once rather than showing yesterday's analysis under today's title (the FuelView rule).
        .onChange(of: scenePhase) { _, phase in if phase == .active { recompute() } }
    }

    // MARK: Hero — the day's verdict

    private var hero: some View {
        VStack(spacing: Theme.Space.md) {
            if let analysis {
                HealthScoreGauge(verdict: analysis.verdict, diameter: 132)
                Text(analysis.headline)
                    .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let counts = bandCountsLine(analysis) {
                    Text(counts)
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
            } else {
                // Honest empty slate — no fake gauge, no sample number.
                ZStack {
                    Circle().stroke(Theme.hairline, lineWidth: 9)
                    Image(systemName: "heart")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .frame(width: 132, height: 132)
                Text("Log a meal and its health score lands here.")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.md)
    }

    /// "5 whole · 2 solid · 1 processed" — the day's food, typed.
    private func bandCountsLine(_ analysis: HealthScore.DayAnalysis) -> String? {
        let parts = HealthScore.Band.allCases.reversed().compactMap { band -> String? in
            guard let n = analysis.bandCounts[band], n > 0 else { return nil }
            return "\(n) \(band.word.lowercased())"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: What shaped it

    private func drivers(_ analysis: HealthScore.DayAnalysis) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("WHAT SHAPED IT")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            VStack(spacing: 0) {
                let rows = analysis.verdict.drivers.prefix(6)
                ForEach(Array(rows.enumerated()), id: \.offset) { i, driver in
                    driverRow(driver, sources: analysis.driverSources[driver.kind] ?? [])
                    if i < rows.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        }
    }

    private func driverRow(_ driver: HealthScore.Driver, sources: [String]) -> some View {
        let lifts = driver.points > 0
        let tint = lifts ? Theme.Fuel.score(.whole) : Theme.Fuel.score(.processed)
        let magnitude = min(1, abs(driver.points) / 20)
        // The WHY under the what: which foods carried this driver, from the engine's own
        // attribution — "Sugars · mostly Soda · Muffin" is what makes the page actionable
        // without ever prescribing. Middle-dot joined (the journal's own list idiom): totals-only
        // meals attribute by the athlete's full sentence, and "and" between two of those reads
        // as one run-on food.
        let sourcesLine = sources.isEmpty ? nil : "mostly \(sources.joined(separator: " · "))"
        return HStack(spacing: Theme.Space.sm) {
            Image(systemName: lifts ? "arrow.up" : "arrow.down")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(driver.kind.label)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                if let sourcesLine {
                    Text(sourcesLine)
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            // The pull, drawn: a short bar scaled to the driver's weight on the day.
            Capsule().fill(tint.opacity(0.8))
                .frame(width: max(8, 56 * magnitude), height: 4)
            Text(String(format: "%+.0f", driver.points))
                .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(driver.kind.label)
        .accessibilityValue("\(driver.points > 0 ? "lifts" : "drags") the score by \(Int(abs(driver.points).rounded())) points"
                            + (sourcesLine.map { ", \($0)" } ?? ""))
    }

    /// The honest caveat — gels and sports drinks are sugar ON PURPOSE.
    private var sportsFuelNote: some View {
        Text("Race fuel reads low by design. Gels and sports drinks are sugar doing their job — judge the pantry, not the workout.")
            .font(.rounded(Theme.FontSize.label, weight: .medium))
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Last 7 days

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("LAST 7 DAYS")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                Spacer(minLength: 0)
                if let weekAverage {
                    Text("avg \(weekAverage)")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                ForEach(week) { day in
                    VStack(spacing: 5) {
                        ZStack(alignment: .bottom) {
                            // Track + fill: bars grow by transform from a fixed 72-pt track, so
                            // an un-logged day still holds its column (an honest gap, not a hole).
                            Capsule().fill(Theme.surface).frame(height: 72)
                            if let v = day.verdict {
                                Capsule()
                                    .fill(Theme.Fuel.score(v.band).opacity(day.isToday ? 1 : 0.75))
                                    .frame(height: max(6, 72 * CGFloat(v.score) / 100))
                            }
                        }
                        Text(day.label)
                            .font(.rounded(9, weight: day.isToday ? .bold : .medium))
                            .foregroundStyle(day.isToday ? Theme.ink : Theme.inkTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.isToday ? "Today" : day.spokenDay)
                    .accessibilityValue(day.verdict.map { "score \($0.score)" } ?? "no meals logged")
                }
            }
        }
    }

    // MARK: Today's food, ranked

    private var rankedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("TODAY'S FOOD, RANKED")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            VStack(spacing: 0) {
                ForEach(ranked) { item in
                    HStack(spacing: Theme.Space.sm) {
                        Circle().fill(Theme.Fuel.score(item.verdict.band))
                            .frame(width: 7, height: 7)
                        Text(item.name)
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(item.portion)
                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.sm)
                        HealthScoreChip(verdict: item.verdict)
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                    if item.id != ranked.last?.id {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        }
    }

    // MARK: The honest footer

    /// Methodology in one breath, then the citations door (App Review 1.4.1: sources easy to
    /// find at the point of the information — a "health score" is exactly such a point).
    private var footer: some View {
        VStack(spacing: Theme.Space.md) {
            Text("Scored 0–100 from what's in the food — fiber, protein and minerals lift it; sugars, saturated fat, refined carbs and ultra-processing drag it. Sodium never counts against you here: it's a training target. Computed on your phone, and every number is an estimate.")
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            SourcesFooterLink()
        }
    }

    // MARK: Compute (once per data change, never in body)

    private func recompute() {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())

        // One walk over the window, bucketed by day. The query is newest-first, so today is a
        // leading prefix and the 7-day cutoff is an early exit.
        guard let cutoff = cal.date(byAdding: .day, value: -6, to: todayStart) else { return }
        var byDay: [Date: [HealthScore.Facts]] = [:]
        var todayRanked: [RankedItem] = []
        for meal in meals {
            if meal.isDeleted { continue }
            guard meal.eatenAt >= cutoff else { break }
            let facts = meal.healthFacts
            guard !facts.isEmpty else { continue }
            byDay[cal.startOfDay(for: meal.eatenAt), default: []].append(contentsOf: facts)
            if meal.eatenAt >= todayStart {
                let items = meal.items
                if items.isEmpty {
                    // Totals-only meal: one ranked row wearing the athlete's own words.
                    if let f = facts.first {
                        todayRanked.append(RankedItem(name: meal.text, portion: "",
                                                      verdict: HealthScore.score(f)))
                    }
                } else {
                    for item in items {
                        todayRanked.append(RankedItem(name: item.name, portion: item.portionLabel,
                                                      verdict: HealthScore.score(item.healthFacts)))
                    }
                }
            }
        }

        analysis = HealthScore.day(byDay[todayStart] ?? [])
        ranked = todayRanked.sorted { $0.verdict.score > $1.verdict.score }

        var bars: [DayBar] = []
        var scores: [Int] = []
        for offset in stride(from: -6, through: 0, by: 1) {
            guard let day = cal.date(byAdding: .day, value: offset, to: todayStart) else { continue }
            let verdict = HealthScore.aggregate(byDay[day] ?? [])
            if let verdict { scores.append(verdict.score) }
            bars.append(DayBar(id: day,
                               label: day.formatted(.dateTime.weekday(.narrow)),
                               spokenDay: day.formatted(.dateTime.weekday(.wide)),
                               verdict: verdict, isToday: offset == 0))
        }
        week = bars
        weekAverage = scores.isEmpty ? nil
            : Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded())
    }
}
