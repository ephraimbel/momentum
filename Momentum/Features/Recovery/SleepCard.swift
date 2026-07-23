import SwiftUI
import Charts

/// The hub's Sleep card (docs/RECOVERY-HUB-PLAN.md §5 row 4) — sleep through a training lens.
/// Last night headlines: duration hero + the stage bar in the single-hue periwinkle depth ramp.
/// Below, the two-week context that decides whether it matters: 7 nights of stacked columns,
/// the 14-day debt curve with its "paid down / building" word, and the bed-and-wake rhythm line.
/// A phone-only night renders a single-tone bar and says so — the card never pretends (§4.4).
///
/// Inputs are engine/service shapes; the card computes nothing but layout:
///  • `report` — `SleepReport.build(from:)`, the headline night + need/debt/consistency.
///  • `nights` — recent `SleepReport.Night`s; the card lays the last 7 mornings on a spine
///    ending at the report's morning. A missing morning renders as a hollow hairline column.
///  • `debt` — the running 14-day debt, one point per day, oldest → newest (built by the
///    segment's `Model.build()` from per-day `SleepReport` runs — off the render path).
struct SleepCard: View {
    let report: SleepReport
    let nights: [SleepReport.Night]
    let debt: [DebtPoint]
    var calendar: Calendar = .current
    /// §8 free/Pro split: free keeps last night (duration hero + stage bar + its footer);
    /// the 7-night columns, debt chart, and consistency row are the Pro depth layer.
    var isPro: Bool = true
    /// Tap-through on the nights section (the Trends detail pattern): month-to-year duration
    /// windows. nil (specimen data, previews) renders no affordance.
    var onOpenNights: (() -> Void)? = nil

    /// One day of the running 14-day sleep-debt series.
    struct DebtPoint: Identifiable, Equatable {
        let day: Date
        let debtH: Double
        var id: Date { day }

        init(day: Date, debtH: Double) {
            self.day = day
            self.debtH = debtH
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    /// §6 trigger 3: the consistency row wears its one-time earned underline this appearance.
    @State private var consistencyEarned = false
    /// Drives the underline's single left-to-right draw-on (scale transform only).
    @State private var underlineDrawn = false

    private var washOpacity: Double {
        colorScheme == .dark ? Theme.Health.darkWashOpacity : Theme.Health.washOpacity
    }
    private let columnChartHeight: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            durationHero
            stageSection
            if isPro {
                divider
                nightsSection
                divider
                debtSection
                divider
                consistencyRow
            }
        }
        .healthCard()
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(Motion.entrance) { appeared = true } }
            armConsistencyShimmer()
        }
    }

    // MARK: Header + duration hero

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Sleep")
                .font(.rounded(Theme.FontSize.headline, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text(nightLabel)
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    private var durationHero: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(hoursMinutes(report.asleepH))
                .font(.display(40, weight: .heavy)).monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text("slept")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 0)
            Text(needLine)
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep duration")
        .accessibilityValue("Slept \(spokenDuration(report.asleepH)). \(needLine)")
    }

    // MARK: Last night's stages (20pt bar, periwinkle depth ramp)

    @ViewBuilder
    private var stageSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let stages = report.stages, stageTotal(stages) > 0 {
                stageBar(stages)
                stageLegend(stages)
                if report.deepBand == nil || report.remBand == nil {
                    // §4.4: no personal band until 10 staged nights — values render bandless.
                    Text("Learning your norm — \(min(report.stageNightCount, 10)) of 10 staged nights")
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                } else if let deep = report.deepBand, let rem = report.remBand {
                    Text("Deep \(deep.rawValue.lowercased()) · REM \(rem.rawValue.lowercased())")
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
            } else {
                // Duration-only night: a single-tone bar, and the honest reason why.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Health.sleepInk)
                    .frame(height: 20)
                    .opacity(appeared ? 1 : 0)
                    .animation(reduceMotion ? nil : Motion.entrance, value: appeared)
                Text("Stages come from a watch worn overnight")
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            footerLine("Deep sleep banks hard training; REM consolidates skill and mood.",
                       explainer: MetricExplainers.sleepStages)
        }
    }

    private func stageBar(_ stages: SleepReport.Stages) -> some View {
        let total = stageTotal(stages)
        let segments = stageSegments(stages)
        return GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: geo.size.width * seg.seconds / total)
                }
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? nil : Motion.entrance, value: appeared)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stages")
        .accessibilityValue(segments.map { "\($0.name) \(spokenDuration($0.seconds / 3_600))" }
            .joined(separator: ", "))
    }

    private func stageLegend(_ stages: SleepReport.Stages) -> some View {
        HStack(spacing: Theme.Space.md) {
            ForEach(Array(stageSegments(stages).enumerated()), id: \.offset) { _, seg in
                HStack(spacing: 4) {
                    Circle().fill(seg.color).frame(width: 6, height: 6)
                    Text("\(seg.name) \(hoursMinutes(seg.seconds / 3_600))")
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .accessibilityHidden(true)   // the bar carries the value
    }

    private func stageSegments(_ s: SleepReport.Stages)
        -> [(name: String, color: Color, seconds: Double)] {
        [("Deep", Theme.Health.sleepDeep, s.deepS),
         ("Core", Theme.Health.sleepCore, s.coreS),
         ("REM", Theme.Health.sleepREM, s.remS),
         ("Awake", Theme.hairline, s.awakeS)]
            .filter { $0.2 > 0 }
            .map { (name: $0.0, color: $0.1, seconds: $0.2) }
    }

    private func stageTotal(_ s: SleepReport.Stages) -> Double {
        s.coreS + s.deepS + s.remS + s.awakeS
    }

    // MARK: 7-night stacked columns

    private var nightsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                sectionLabel("LAST 7 NIGHTS")
                Spacer(minLength: 0)
                if onOpenNights != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            VStack(spacing: 4) {
                ZStack(alignment: .bottom) {
                    gridlines
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(nightSpine.enumerated()), id: \.element.day) { i, entry in
                            columnView(entry, index: i)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.trailing, 28)   // gutter for the hour labels
                }
                .frame(height: columnChartHeight)
                HStack(spacing: 0) {
                    ForEach(nightSpine, id: \.day) { entry in
                        Text(dayLetter(entry.day))
                            .font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.trailing, 28)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last 7 nights")
            .accessibilityValue(nightsAccessibilityValue)
            .accessibilityAddTraits(onOpenNights != nil ? .isButton : [])
            .accessibilityHint(onOpenNights != nil ? "Shows the full trend" : "")
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenNights?() }
    }

    private struct NightEntry {
        let day: Date
        let night: SleepReport.Night?
    }

    /// The last 7 mornings ending at the report's morning; missing mornings stay on the spine.
    private var nightSpine: [NightEntry] {
        let end = calendar.startOfDay(for: report.date)
        var byDay: [Date: SleepReport.Night] = [:]
        for night in nights {
            let key = calendar.startOfDay(for: night.date)
            // Two records on one morning: keep the longer night (mirrors the service's merge).
            if let existing = byDay[key], existing.asleepH >= night.asleepH { continue }
            byDay[key] = night
        }
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            return NightEntry(day: day, night: byDay[day])
        }
    }

    /// Stacked hours for a night: staged nights stack deep/core/REM; duration-only nights are a
    /// single tone. Awake is not sleep — it never joins the column.
    private func stackedHours(_ night: SleepReport.Night)
        -> [(color: Color, hours: Double)]? {
        // Built imperatively with explicit types — the tuple-literal + filter + map chain sent the
        // type-checker into "unable to type-check in reasonable time".
        var parts: [(color: Color, hours: Double)] = []
        let deep = (night.deepS ?? 0) / 3_600
        let core = (night.coreS ?? 0) / 3_600
        let rem = (night.remS ?? 0) / 3_600
        if deep > 0 { parts.append((color: Theme.Health.sleepDeep, hours: deep)) }
        if core > 0 { parts.append((color: Theme.Health.sleepCore, hours: core)) }
        if rem > 0 { parts.append((color: Theme.Health.sleepREM, hours: rem)) }
        return parts.isEmpty ? nil : parts
    }

    private func columnHours(_ night: SleepReport.Night) -> Double {
        stackedHours(night)?.reduce(0) { $0 + $1.hours } ?? night.asleepH
    }

    /// Y-scale ceiling: an even number of hours covering every column (and the hollow "need"
    /// ghost), never below 8 so a short week doesn't dramatize itself.
    private var maxScaleHours: Double {
        let tallest = nightSpine.compactMap { $0.night.map(columnHours) }.max() ?? 0
        return max(8, ((max(tallest, report.needH)) / 2).rounded(.up) * 2)
    }

    @ViewBuilder
    private func columnView(_ entry: NightEntry, index: Int) -> some View {
        let maxH = maxScaleHours
        Group {
            if let night = entry.night {
                if let parts = stackedHours(night) {
                    VStack(spacing: 1) {
                        // Drawn top-down, so deep sits on the floor of the column.
                        ForEach(Array(parts.reversed().enumerated()), id: \.offset) { _, part in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(part.color)
                                .frame(height: max(2, columnChartHeight * part.hours / maxH))
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.Health.sleepInk)
                        .frame(height: max(3, columnChartHeight * night.asleepH / maxH))
                }
            } else {
                // Missing night — hollow hairline column at the athlete's need, never zero-filled.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
                    .frame(height: columnChartHeight * report.needH / maxH)
            }
        }
        .frame(width: 14)
        .scaleEffect(y: appeared ? 1 : 0.001, anchor: .bottom)
        .animation(reduceMotion ? nil : Motion.entrance.delay(0.06 * Double(index)),
                   value: appeared)
    }

    private var gridlines: some View {
        let maxH = maxScaleHours
        return GeometryReader { geo in
            ForEach(Array(stride(from: 2.0, through: maxH, by: 2.0)), id: \.self) { h in
                let y = geo.size.height * (1 - h / maxH)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                    .offset(y: y)
                if h.truncatingRemainder(dividingBy: 4) == 0 {
                    // Tucked just under its line, in the trailing gutter the columns leave free.
                    Text("\(Int(h))h")
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: y + 3)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var nightsAccessibilityValue: String {
        nightSpine.map { entry in
            guard let night = entry.night else { return "no data" }
            return spokenDuration(night.asleepH)
        }
        .joined(separator: ", ")
    }

    // MARK: 14-day debt

    private var debtSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("SLEEP DEBT")
                    .accessibilityHidden(true)   // the collapsed block below speaks "Sleep debt"
                Spacer(minLength: Theme.Space.sm)
                // Outside the ignored element so VoiceOver can still reach the ⓘ.
                MetricInfoButton(explainer: MetricExplainers.sleepDebt)
            }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(debtHeadline)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
                if debt.count >= 2 {
                    debtChart
                } else {
                    Text("A week of nights will draw your debt line here.")
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
                footerLine("Debt compounds quietly — and pays down fast within a couple of honest nights.",
                           explainer: nil)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep debt")
            .accessibilityValue(debtHeadline)
        }
    }

    private var debtChart: some View {
        let maxDebt = debt.map(\.debtH).max() ?? 1
        return Chart {
            ForEach(debt) { point in
                AreaMark(x: .value("Day", point.day),
                         y: .value("Debt", appeared ? point.debtH : 0))
                    .foregroundStyle(LinearGradient(
                        colors: [Theme.Health.sleepWash.opacity(washOpacity * 2),
                                 Theme.Health.sleepWash.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", point.day),
                         y: .value("Debt", appeared ? point.debtH : 0))
                    .foregroundStyle(Theme.Health.sleepInk)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            // The zero line is the story — "caught up" is a place on this chart.
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Theme.inkSecondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartYScale(domain: 0...max(1, maxDebt * 1.15))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .frame(height: 84)
    }

    private var debtHeadline: String {
        if report.debt14H < 0.25 { return "No debt — all caught up" }
        let amount = String(format: "%.1f", report.debt14H)
        return "\(amount) h short over 14 nights · \(debtWord)"
    }

    /// "paid down / building" (§5): the last point against roughly a week earlier.
    private var debtWord: String {
        guard let last = debt.last?.debtH, let first = debt.first?.debtH else { return "steady" }
        let reference = debt.count >= 8 ? debt[debt.count - 8].debtH : first
        if last < reference - 0.25 { return "being paid down" }
        if last > reference + 0.25 { return "building" }
        return "steady"
    }

    // MARK: Consistency

    private var consistencyRow: some View {
        HStack(spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                Text(consistencyLine)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .bottomLeading) {
                        if consistencyEarned {
                            consistencyUnderline.offset(y: 6)
                        }
                    }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Theme.Space.sm)
            // Outside the combined element so VoiceOver can still reach the ⓘ.
            MetricInfoButton(explainer: MetricExplainers.sleepConsistency)
        }
    }

    private var consistencyLine: String {
        guard let drift = report.midpointDriftMin else {
            return "Learning your rhythm — a few more nights"
        }
        let word: String = switch report.consistencyBand {
        case .good: "steady"
        case .fair: "drifting a little"
        case .low: "worth steadying"
        case nil: "steady"
        }
        return "Bed-and-wake rhythm ±\(Int(drift.rounded())) min · \(word)"
    }

    // MARK: Earned shimmer (§6 trigger 3 — the sleep-consistency milestone)

    /// A good rhythm (drift ≤ 45 min) held across all 7 visible nights earns a one-time subtle
    /// iridescent underline — once ever (persisted). Streak spirit: it celebrates, then stands
    /// down — never "lost", never pressure.
    private func armConsistencyShimmer() {
        guard isPro, report.consistencyBand == .good,
              nightSpine.allSatisfy({ $0.night != nil }),
              HealthShimmerGate.claim("health.shimmer.consistency.7")
        else { return }
        consistencyEarned = true
        if reduceMotion { underlineDrawn = true }   // static — it shows, it doesn't move
        else { withAnimation(.easeOut(duration: 1.2).delay(0.5)) { underlineDrawn = true } }
    }

    /// The earned underline: a hairline of the iridescent mesh drawing on left-to-right
    /// (scale transform only), then holding still — it never loops.
    private var consistencyUnderline: some View {
        IridescentView(intensity: 0.9, isStatic: true)
            .frame(height: 3)
            .clipShape(Capsule())
            .scaleEffect(x: underlineDrawn ? 1 : 0.001, anchor: .leading)
            .allowsHitTesting(false)
    }

    // MARK: Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
            .foregroundStyle(Theme.inkTertiary)
    }

    /// A §7 one-line education footer, ending in ⓘ when it has a sheet.
    private func footerLine(_ text: String, explainer: MetricExplainer?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(text)
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let explainer {
                Spacer(minLength: 0)
                MetricInfoButton(explainer: explainer)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private var nightLabel: String {
        if calendar.isDateInToday(report.date) { return "Last night" }
        return "Night of " + report.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var needLine: String {
        let shortfall = report.needH - report.asleepH
        if shortfall <= 0 { return "Need \(hoursMinutes(report.needH)) · met" }
        return "Need \(hoursMinutes(report.needH)) · \(shortText(shortfall)) short"
    }

    private func shortText(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return minutes < 60 ? "\(minutes) min" : hoursMinutes(hours)
    }

    /// "7:41" — hours:minutes, the duration-hero format.
    private func hoursMinutes(_ hours: Double) -> String {
        let totalMinutes = max(0, Int((hours * 60).rounded()))
        return "\(totalMinutes / 60):" + String(format: "%02d", totalMinutes % 60)
    }

    private func spokenDuration(_ hours: Double) -> String {
        let totalMinutes = max(0, Int((hours * 60).rounded()))
        return "\(totalMinutes / 60) hours \(totalMinutes % 60) minutes"
    }

    private func dayLetter(_ date: Date) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }
}

// MARK: - Preview

#Preview("SleepCard") {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let nights: [SleepReport.Night] = (0..<7).compactMap { offset in
        guard offset != 3,   // one missing morning → hollow column
              let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
        let asleep = [7.7, 6.9, 8.1, 0, 7.2, 6.4, 7.9][offset]
        return SleepReport.Night(
            date: day, asleepH: asleep,
            coreS: asleep * 3_600 * 0.55, deepS: asleep * 3_600 * 0.18,
            remS: asleep * 3_600 * 0.22, awakeS: asleep * 3_600 * 0.05,
            inBedS: asleep * 3_600 * 1.06,
            sleepStart: cal.date(byAdding: .hour, value: -8, to: day),
            sleepEnd: cal.date(byAdding: .hour, value: -1, to: day))
    }
    let debt = (0..<14).reversed().compactMap { offset -> SleepCard.DebtPoint? in
        guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
        return SleepCard.DebtPoint(day: day, debtH: max(0, 4.5 - Double(14 - offset) * 0.25))
    }
    return ScrollView {
        if let report = SleepReport.build(from: nights) {
            SleepCard(report: report, nights: nights, debt: debt)
                .padding()
        }
    }
    .background(Theme.background)
}
