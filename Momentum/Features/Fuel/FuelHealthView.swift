import SwiftUI
import SwiftData
import Charts

/// The nutrition report (grown from the 2026-08-15 health-score page) — behind the Fuel masthead's
/// gauge. One page that answers "how am I actually eating?", today first and then the month:
/// the day's score as a hero gauge, what moved it (the engine's signed drivers, plain words),
/// today's foods ranked — then the last 30 days as real charts (score, energy), floor consistency
/// counted in days met, the processed share by week, the foods that keep recurring, and the
/// monthly mineral picture (the one sanctioned micro surface — a month is the scale they move on).
///
/// Every number is deterministic engine math (`HealthScore` + `FuelTrends`), computed on-device
/// from the nutrition facts meals already carry — nothing here bills a call. Framing rules: the
/// score judges the FOOD, never the athlete; "Processed" is a description, not a verdict on a
/// person; race fuel reads low by design and the page says so; floors are consistency, never
/// restriction. No diet, weight, or medical language.
struct FuelHealthView: View {
    /// Newest-first, bounded like the main page's journal window: the page reads today plus a
    /// 30-day report — 400 rows ≈ 13 meals a day for the whole window, comfortably more than
    /// anyone logs.
    private static var recentMeals: FetchDescriptor<Meal> {
        var d = FetchDescriptor<Meal>(sortBy: [SortDescriptor(\Meal.eatenAt, order: .reverse)])
        d.fetchLimit = 400
        return d
    }
    @Query(FuelHealthView.recentMeals) private var meals: [Meal]
    @Query private var profiles: [UserProfile]
    @Environment(\.scenePhase) private var scenePhase

    /// One ranked food from today's journal.
    private struct RankedItem: Identifiable {
        let id = UUID()
        let name: String
        let portion: String
        let verdict: HealthScore.Verdict
    }

    // Computed ONCE per data change (the page-load rule: no engine work in body) — decoding a
    // month of `itemsData` per render pass is exactly what the main page's caches exist to avoid.
    @State private var analysis: HealthScore.DayAnalysis?
    @State private var ranked: [RankedItem] = []
    @State private var report: FuelTrends.Report?
    /// What the current compute was built from — estimates land on EXISTING rows (same count),
    /// so the trigger must taste content, not just count (the FuelView signature lesson).
    @State private var computedSignature: Int?

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
                if !ranked.isEmpty {
                    rankedSection.reveal(0.16)
                }
                if let report {
                    monthScoreSection(report).reveal(0.20)
                    energySection(report).reveal(0.24)
                    floorsSection(report).reveal(0.28)
                    // Gated on NOVA sampling: without processing classes (totals-only histories)
                    // the processed band almost never fires and a "0%" here would be a false
                    // measurement, not a good month. A true 0% over classified food DOES render —
                    // that's the state worth seeing.
                    if report.weeks.count >= 2, report.novaSampled {
                        qualitySection(report).reveal(0.32)
                    }
                    if !report.topFoods.isEmpty {
                        topFoodsSection(report).reveal(0.36)
                    }
                    if let micros = report.micros {
                        microSection(micros).reveal(0.40)
                    }
                }
                footer.reveal(0.44)
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        #if DEBUG
        // --fuel-health-bottom: open pre-scrolled to the month sections (simctl can't scroll) —
        // the staples/minerals half of the report is below the fold on every device.
        .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("--fuel-health-bottom") ? .bottom : .top)
        #endif
        .background(Theme.background)
        .navigationTitle("Nutrition")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recomputeIfNeeded() }
        .onChange(of: contentSignature) { recomputeIfNeeded() }
        // Foregrounding after hours asleep: "today" is baked into the buckets, so re-judge at
        // once rather than showing yesterday's analysis under today's title (the FuelView rule).
        .onChange(of: scenePhase) { _, phase in if phase == .active { recomputeIfNeeded(force: true) } }
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
            sectionTitle("WHAT SHAPED IT")
            VStack(spacing: 0) {
                let rows = analysis.verdict.drivers.prefix(6)
                ForEach(Array(rows.enumerated()), id: \.offset) { i, driver in
                    driverRow(driver, sources: analysis.driverSources[driver.kind] ?? [])
                    if i < rows.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    }
                }
            }
            .background(cardShape)
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

    // MARK: Today's food, ranked

    private var rankedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("TODAY'S FOOD, RANKED")
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
            .background(cardShape)
        }
    }

    // MARK: The last 30 days — score

    /// Daily score bars over the month. Band tints are REDUNDANT encoding here (a bar's height IS
    /// its score; the tint restates the band the height already lands in), so the citrus/rooibos
    /// closeness that rules out a color-only composition chart costs nothing — a reader who can't
    /// split those hues reads the same chart from position alone.
    private func monthScoreSection(_ report: FuelTrends.Report) -> some View {
        let scored = report.days.filter { $0.logged && $0.score != nil }
        let dates = scored.map(\.day)
        let today = report.days.last?.day
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("THE LAST 30 DAYS")
                Spacer(minLength: 0)
                if let avg = report.avgScore {
                    Text("avg \(avg)")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            if scored.count >= 2 {
                Chart {
                    ForEach(scored) { d in
                        BarMark(x: .value("Day", d.day),
                                y: .value("Score", d.score ?? 0),
                                width: .fixed(5))
                            .foregroundStyle(Theme.Fuel.score(d.band ?? .mixed)
                                .opacity(d.day == today ? 1 : 0.75))
                            .cornerRadius(2)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: TrendAxis.domain(for: report.days.map(\.day), granularity: .daily))
                .chartXAxis { TrendAxis.marks(for: dates, granularity: .daily) }
                .chartYAxis { scoreAxis }
                .frame(height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Health score, last 30 days")
                .accessibilityValue(report.avgScore.map { "average \($0), \(scored.count) days scored" } ?? "")
            } else {
                thinSample("A few more logged days and the month takes shape.")
            }
        }
    }

    /// 0 · 50 · 100 — a quiet ruler for a bounded score, nothing more.
    private var scoreAxis: some AxisContent {
        AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel().font(TrendAxis.labelFont).foregroundStyle(Theme.inkTertiary)
        }
    }

    // MARK: Energy

    /// kcal by day against the everyday floor (30 kcal/kg — the constant yardstick; the true
    /// day-by-day floor moves with training and isn't reconstructable in hindsight). Floors
    /// doctrine: the line asks "fueled enough?", never "under the cap?".
    private func energySection(_ report: FuelTrends.Report) -> some View {
        let logged = report.days.filter(\.logged)
        let dates = logged.map(\.day)
        let today = report.days.last?.day
        let maxKcal = logged.map(\.kcal).max() ?? 0
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("ENERGY")
                Spacer(minLength: 0)
                if let avg = report.avgKcal {
                    Text("avg \(avg.formatted()) kcal")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            if logged.count >= 2 {
                Chart {
                    ForEach(logged) { d in
                        BarMark(x: .value("Day", d.day),
                                y: .value("kcal", d.kcal),
                                width: .fixed(5))
                            .foregroundStyle(d.day == today ? AnyShapeStyle(IridescentMaterial())
                                                            : AnyShapeStyle(Theme.ink.opacity(0.72)))
                            .cornerRadius(2)
                    }
                    RuleMark(y: .value("Floor", report.kcalFloor))
                        .foregroundStyle(Theme.inkTertiary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("everyday floor")
                                .font(.rounded(9, weight: .bold))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                }
                .chartYScale(domain: 0...max(Double(maxKcal) * 1.15, Double(report.kcalFloor) * 1.25))
                .chartXScale(domain: TrendAxis.domain(for: report.days.map(\.day), granularity: .daily))
                .chartXAxis { TrendAxis.marks(for: dates, granularity: .daily) }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(Formatters.compact(v)) }
                        }
                        .font(TrendAxis.labelFont).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .frame(height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Energy, last 30 days")
                .accessibilityValue(report.avgKcal.map { "average \($0) kilocalories a day over \(logged.count) logged days" } ?? "")
            } else {
                thinSample("Log a couple of days and the energy picture lands here.")
            }
        }
    }

    // MARK: Floors hit — consistency, never restriction

    private func floorsSection(_ report: FuelTrends.Report) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("FLOORS HIT")
            VStack(spacing: 0) {
                floorRow(label: "Carbs", ink: Theme.Fuel.carbs,
                         met: report.carbsDaysMet, of: report.loggedDays,
                         floorText: "\(report.carbsFloorG) g easy-day floor")
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                floorRow(label: "Protein", ink: Theme.Fuel.protein,
                         met: report.proteinDaysMet, of: report.loggedDays,
                         floorText: "\(report.proteinFloorG) g floor")
            }
            .background(cardShape)
            Text("Counted across the \(report.loggedDays) logged day\(report.loggedDays == 1 ? "" : "s") this month. Session days ask for more carbs than this everyday floor — the dashboard tracks that live.")
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Stacked gauge cell (the readout sheet's own grammar): label and count share the top line,
    /// the capsule runs full width beneath — no fixed columns, so nothing can ever truncate
    /// ("Potassium" was losing its tail to a squeezed three-column row, owner report 2026-08-20).
    private func floorRow(label: String, ink: Color, met: Int, of total: Int, floorText: String) -> some View {
        let fraction = total > 0 ? Double(met) / Double(total) : 0
        // Every logged day met the floor — that consistency is the earned moment (needs a real
        // sample, not a perfect single day).
        let earned = total >= 5 && met == total
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(label)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                    .fixedSize()
                Text(floorText)
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                Text("\(met) of \(total) days")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize()
            }
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(Theme.surface)
                    Capsule()
                        .fill(earned ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(ink))
                        .frame(width: max(5, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) floor")
        .accessibilityValue("met on \(met) of \(total) logged days")
    }

    // MARK: What you eat — the processed share

    /// One honest composition number per week: the share of food energy scoring in the processed
    /// band. A single raspberry hue — the four band colors are identity elsewhere, but citrus and
    /// rooibos sit ΔE ≈ 3 apart (validated 2026-08-20), far too close to carry a stacked
    /// composition on color alone, so the composition question collapses to its one actionable
    /// slice. Height is the message; the hue just names the band.
    private func qualitySection(_ report: FuelTrends.Report) -> some View {
        let weeks = report.weeks
        let dates = weeks.map(\.weekStart)
        let latest = weeks.last
        let maxShare = weeks.map(\.processedShare).max() ?? 0
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("PROCESSED SHARE")
                Spacer(minLength: 0)
                if let latest {
                    Text("this week \(Int((latest.processedShare * 100).rounded()))%")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            Chart {
                ForEach(weeks) { wk in
                    BarMark(x: .value("Week", wk.weekStart),
                            y: .value("Share", wk.processedShare * 100),
                            width: .fixed(18))
                        .foregroundStyle(Theme.Fuel.score(.processed)
                            .opacity(wk.weekStart == latest?.weekStart ? 1 : 0.7))
                        .cornerRadius(3)
                }
            }
            .chartYScale(domain: 0...max(50, maxShare * 100 * 1.3))
            .chartXScale(domain: TrendAxis.domain(for: dates, granularity: .weekly))
            .chartXAxis { TrendAxis.marks(for: dates, granularity: .weekly) }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text("\(Int(v))%") }
                    }
                    .font(TrendAxis.labelFont).foregroundStyle(Theme.inkTertiary)
                }
            }
            .frame(height: 120)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Processed share by week")
            .accessibilityValue(latest.map { "\(Int(($0.processedShare * 100).rounded())) percent of this week's calories" } ?? "")
            Text("Share of each week's food energy from processed-scoring food. Race fuel counts here — a gel week isn't a junk week, it's a training week.")
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The foods that keep showing up

    private func topFoodsSection(_ report: FuelTrends.Report) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("YOUR STAPLES THIS MONTH")
            VStack(spacing: 0) {
                ForEach(report.topFoods) { food in
                    HStack(spacing: Theme.Space.sm) {
                        Circle().fill(food.verdict.map { Theme.Fuel.score($0.band) } ?? Theme.hairline)
                            .frame(width: 7, height: 7)
                        Text(food.name)
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text("×\(food.count)")
                            .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Theme.inkTertiary)
                        Spacer(minLength: Theme.Space.sm)
                        if let verdict = food.verdict {
                            HealthScoreChip(verdict: verdict)
                        }
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                    if food.id != report.topFoods.last?.id {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    }
                }
            }
            .background(cardShape)
        }
    }

    // MARK: Minerals this month

    /// The sanctioned micro surface (daily rings retired 2026-07-16): monthly daily-averages
    /// against the same sex-aware floors the readout uses. Cells stay monochrome — the micro inks
    /// remain reserved (palette doctrine); the insight line does the pointing.
    private func microSection(_ micros: FuelTrends.MicroMonth) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionTitle("MINERALS THIS MONTH")
            VStack(spacing: 0) {
                ForEach(Array(micros.lines.enumerated()), id: \.offset) { i, line in
                    // Same stacked cell as the floors card: the label owns its line end to end
                    // ("Potassium" was clipping in the old three-column squeeze) and the capsule
                    // runs full width beneath.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                            Text(line.label)
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                                .fixedSize()
                            Spacer(minLength: Theme.Space.sm)
                            // Unknown, never zero: a micro no meal carried renders "—", not a
                            // fabricated 0-mg average (the nutrition grid's rule, at month scale).
                            Text(line.sampled ? "\(compactMg(line.avg)) of \(compactMg(line.floor)) \(line.unit) a day"
                                              : "—")
                                .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                                .foregroundStyle(Theme.inkTertiary)
                                .fixedSize()
                        }
                        ZStack(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule().fill(Theme.surface)
                                if line.sampled {
                                    Capsule()
                                        .fill(line.coverage >= 1 ? AnyShapeStyle(IridescentMaterial())
                                                                 : AnyShapeStyle(Theme.ink.opacity(0.6)))
                                        .frame(width: max(5, geo.size.width * line.coverage))
                                }
                            }
                        }
                        .frame(height: 5)
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line.label)
                    .accessibilityValue(line.sampled
                        ? "averaging \(compactMg(line.avg)) of \(compactMg(line.floor)) \(line.unit) a day"
                        : "not estimated this month")
                    if i < micros.lines.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    }
                }
            }
            .background(cardShape)
            if let insight = micros.insight {
                Text(insight)
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func compactMg(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v.rounded()))"
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

    // MARK: Small shared pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
            .foregroundStyle(Theme.inkTertiary)
    }

    private var cardShape: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Theme.surface.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }

    private func thinSample(_ line: String) -> some View {
        Text(line)
            .font(.rounded(Theme.FontSize.label, weight: .medium))
            .foregroundStyle(Theme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Compute (once per data change, never in body)

    /// Cheap content taste — count alone misses an estimate landing on an existing row (the exact
    /// gap the old page had): the newest rows' values fold in, so a resolved estimate, an edit,
    /// or a delete all retrigger. Bounded at 60 rows; older meals don't change under the page.
    private var contentSignature: Int {
        var h = Hasher()
        h.combine(meals.count)
        for meal in meals.prefix(60) {
            h.combine(meal.kcal ?? -1)
            h.combine(meal.carbsG ?? -1)
            h.combine(meal.source)
            h.combine(meal.eatenAt)
        }
        h.combine(Calendar.current.startOfDay(for: Date()))
        return h.finalize()
    }

    private func recomputeIfNeeded(force: Bool = false) {
        let signature = contentSignature
        guard force || signature != computedSignature else { return }
        computedSignature = signature
        recompute()
    }

    private func recompute() {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)

        // One walk over the window: today's analysis + ranked list, and the engine inputs for
        // the month report. The query is newest-first, so the 30-day cutoff is an early exit.
        guard let cutoff = cal.date(byAdding: .day, value: -29, to: todayStart) else { return }
        var todayFacts: [HealthScore.Facts] = []
        var todayRanked: [RankedItem] = []
        var inputs: [FuelTrends.MealInput] = []
        for meal in meals {
            if meal.isDeleted { continue }
            guard meal.eatenAt >= cutoff else { break }
            let facts = meal.healthFacts
            inputs.append(FuelTrends.MealInput(eatenAt: meal.eatenAt, kcal: meal.kcal,
                                               carbsG: meal.carbsG, proteinG: meal.proteinG,
                                               facts: facts,
                                               potassiumMg: meal.potassiumMg,
                                               magnesiumMg: meal.magnesiumMg,
                                               ironMg: meal.ironMg, calciumMg: meal.calciumMg))
            guard !facts.isEmpty else { continue }
            if meal.eatenAt >= todayStart {
                todayFacts.append(contentsOf: facts)
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

        analysis = HealthScore.day(todayFacts)
        ranked = todayRanked.sorted { $0.verdict.score > $1.verdict.score }

        let profile = profiles.first
        report = FuelTrends.report(meals: inputs,
                                   bodyMassKg: profile?.bodyMassKg,
                                   isMale: profile?.sex == "male" ? true
                                       : (profile?.sex == "female" ? false : nil),
                                   now: now, calendar: cal)
    }
}
