import SwiftUI

/// "Weekly rhythm" — the Health segment's 4-week × 7-day heat-dot grid of `DayStrain`
/// (docs/RECOVERY-HUB-PLAN.md §5 row 6, §11.2.4, §11.2.6). Each day is one peach-ink dot whose
/// opacity (0.25/0.5/0.75/1.0) AND size (6→10pt) step with the strain quartile — the double
/// encoding survives grayscale and CVD. Kept rest days render proudly as a hollow ring with a
/// tick (part of the program, not a hole in it); today wears an ink ring. Tapping a dot opens a
/// popover naming where the strain came from ("Strain 62 — mostly the tempo, plus a 14k-step
/// day") from the engine's `workoutLoad`/`ambientLoad` split.
///
/// The footer renders `RecoveryModel.monotony`'s missing conclusion (§11.2.4) in words only —
/// the internal name never surfaces. Strain quartiles are the engine's own band cuts (25/50/75
/// — quartiles of the 0–100 scale), so history never repaints as new days land.
struct RhythmCard: View {
    /// One spine day. Provide 28, oldest → today; `strain == nil` is a data hole (rendered as a
    /// quiet hairline dot, never a fake zero).
    struct Day: Identifiable {
        var date: Date
        var strain: DayStrain?
        /// Plan-sourced flag: the plan prescribed rest here.
        var isRestDayPlanned: Bool = false
        /// Names the day's headline session for the tap summary — "the tempo", "the long run".
        /// Falls back to plain "training" when absent; never invents specifics.
        var workoutName: String?
        /// Day's non-workout steps, for the "plus a 14k-step day" beat of the tap summary.
        var ambientSteps: Double?
        var id: Date { date }

        init(date: Date,
             strain: DayStrain? = nil,
             isRestDayPlanned: Bool = false,
             workoutName: String? = nil,
             ambientSteps: Double? = nil) {
            self.date = date
            self.strain = strain
            self.isRestDayPlanned = isRestDayPlanned
            self.workoutName = workoutName
            self.ambientSteps = ambientSteps
        }
    }

    /// 28 spine days, oldest → today (extra leading days are dropped, never re-bucketed).
    let days: [Day]
    /// `RecoveryModel.monotony` (7-day mean daily load ÷ SD) — worded footer verdict; nil hides
    /// the line rather than guessing.
    var monotony: Double?
    /// §6 trigger 2, caller-passed: the most recent complete week sat "balanced" in
    /// `StrainRecoveryBalance` — that row earns its one-time shimmer.
    var lastWeekBalanced: Bool = false
    var calendar: Calendar = .current

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var selectedDay: Date?
    /// Index of the week row wearing the earned shimmer this appearance; nil = none earned.
    @State private var shimmerWeekIndex: Int?
    /// 0→1 drives the masked sweep's offset across the row (transform only).
    @State private var shimmerSweep: CGFloat = 0

    /// Dot centers per §5 row 6.
    private let cellSize: CGFloat = 24

    private var weeks: [[Day]] {
        let spine = Array(days.suffix(28))
        return stride(from: 0, to: spine.count, by: 7).map { Array(spine[$0..<min($0 + 7, spine.count)]) }
    }

    /// Column letters come from the last full week's real dates, so the header always matches
    /// whatever weekday the spine starts on.
    private var weekdayLetters: [String] {
        guard let lastFull = weeks.last(where: { $0.count == 7 }) else { return [] }
        return lastFull.map { $0.date.formatted(.dateTime.weekday(.narrow)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            grid
            legend
            if let monotony {
                // §11.2.4 — the monotony verdict, worded, never the internal name. The cut sits
                // where `RecoveryModel` starts docking readiness for sameness (monotony ≥ 1.5).
                Text(monotony < 1.5
                     ? "Good variety this week — hard days hard, easy days easy."
                     : "Days are blurring to medium — that's where strain builds quietly.")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)))
        .onAppear {
            appeared = true
            armWeekShimmer()
        }
    }

    // MARK: Header · legend · footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Weekly rhythm")
                .font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Four weeks of strain, day by day")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var legend: some View {
        HStack(spacing: Theme.Space.lg) {
            HStack(spacing: 4) {
                ForEach(Array(bandScale.enumerated()), id: \.offset) { _, band in
                    Circle()
                        .fill(Theme.Health.strainInk.opacity(dotOpacity(band)))
                        .frame(width: dotSize(band) * 0.8, height: dotSize(band) * 0.8)
                }
                Text("Light → Peak")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .padding(.leading, 2)
            }
            HStack(spacing: 5) {
                restGlyph(diameter: 8)
                Text("Planned rest")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
        }
        .accessibilityHidden(true)   // each dot carries its own label
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Text("Kept rest days count — they're part of the program, not a hole in it.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.sm)
            MetricInfoButton(explainer: MetricExplainers.restDays)
        }
    }

    // MARK: Grid

    private var grid: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                if !weekdayLetters.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(weekdayLetters.enumerated()), id: \.offset) { _, letter in
                            Text(letter)
                                .font(.rounded(9, weight: .bold))
                                .foregroundStyle(Theme.inkTertiary)
                                .frame(width: cellSize, height: 14)
                        }
                    }
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { weekIndex, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.element.id) { column, day in
                            cell(day, column: column)
                        }
                    }
                    .overlay {
                        if shimmerWeekIndex == weekIndex { weekShimmer(week) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func cell(_ day: Day, column: Int) -> some View {
        Button {
            selectedDay = day.id
        } label: {
            dot(day)
                .frame(width: cellSize, height: cellSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: popoverBinding(day)) {
            DaySummaryPopover(day: day)
                .presentationCompactAdaptation(.popover)
        }
        // Ripple in by column, 20ms apart (§5 row 6); Reduce Motion collapses to one plain fade.
        .opacity(appeared ? 1 : 0)
        .scaleEffect(reduceMotion || appeared ? 1 : 0.4)
        .animation(reduceMotion ? .easeOut(duration: Motion.normal)
                                : Motion.standard.delay(Double(column) * 0.02),
                   value: appeared)
        .accessibilityLabel(a11yLabel(day))
    }

    @ViewBuilder
    private func dot(_ day: Day) -> some View {
        ZStack {
            if isKeptRest(day) {
                restGlyph(diameter: 8)
            } else if let strain = day.strain {
                Circle()
                    .fill(Theme.Health.strainInk.opacity(dotOpacity(strain.band)))
                    .frame(width: dotSize(strain.band), height: dotSize(strain.band))
            } else {
                // A data hole — quiet hairline dot, silently degraded, never a warning.
                Circle().fill(Theme.hairline).frame(width: 4, height: 4)
            }
        }
        .overlay {
            if calendar.isDate(day.date, inSameDayAs: .now) {
                Circle().stroke(Theme.ink, lineWidth: 1.5).frame(width: 16, height: 16)
            }
        }
    }

    /// Hollow ring + centered tick — the kept rest day, worn proudly in structural ink.
    private func restGlyph(diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Theme.inkSecondary, lineWidth: 1.2)
                .frame(width: diameter, height: diameter)
            Image(systemName: "checkmark")
                .font(.system(size: diameter * 0.5, weight: .black))
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    /// A planned rest day reads as kept while nothing meaningful landed on it; a real session on
    /// a rest day honestly shows its strain dot instead.
    private func isKeptRest(_ day: Day) -> Bool {
        day.isRestDayPlanned && (day.strain?.score ?? 0) < 25
    }

    private var bandScale: [DayStrain.Band] { [.light, .moderate, .hard, .peak] }

    /// §5 row 6 — quartile steps carried by BOTH channels.
    private func dotOpacity(_ band: DayStrain.Band) -> Double {
        switch band {
        case .light: 0.25
        case .moderate: 0.5
        case .hard: 0.75
        case .peak: 1.0
        }
    }

    private func dotSize(_ band: DayStrain.Band) -> CGFloat {
        switch band {
        case .light: 6
        case .moderate: 7.5
        case .hard: 8.5
        case .peak: 10
        }
    }

    // MARK: Earned shimmer (§6 trigger 2 — a balanced week completed)

    /// The most recent week row with all 7 dots present (a strain reading or a planned rest on
    /// every day) — the only row that can wear the earned shimmer.
    private var completeWeekIndex: Int? {
        weeks.lastIndex { week in
            week.count == 7 && week.allSatisfy { $0.strain != nil || $0.isRestDayPlanned }
        }
    }

    /// Fires at most once per week ever (persisted per week-start) and once per appearance —
    /// a single 1.2s sweep, never looping. Reduce Motion earns the same moment as a static
    /// iridescent tint on the row's dots: the achievement shows, it just doesn't move.
    private func armWeekShimmer() {
        guard lastWeekBalanced,
              let index = completeWeekIndex,
              let weekStart = weeks[index].first?.date,
              HealthShimmerGate.claim("health.shimmer.week.\(isoDay(weekStart))")
        else { return }
        shimmerWeekIndex = index
        guard !reduceMotion else { return }
        // Let the dots ripple in first, then one masked sweep across the row.
        withAnimation(.easeInOut(duration: 1.2).delay(0.7)) { shimmerSweep = 1 }
    }

    /// One iridescent sweep masked to the row's own dots (Reduce Motion: a static tint).
    /// Transforms/opacity only; decorative — it never intercepts the dot taps.
    private func weekShimmer(_ week: [Day]) -> some View {
        GeometryReader { geo in
            IridescentView(intensity: reduceMotion ? 0.55 : 0.95, isStatic: true)
                .mask {
                    if reduceMotion {
                        Rectangle()
                    } else {
                        // A 30%-width band travelling fully off-left → fully off-right.
                        Rectangle()
                            .frame(width: geo.size.width * 0.3)
                            .offset(x: (shimmerSweep - 0.5) * geo.size.width * 1.3)
                    }
                }
        }
        .mask { rowDots(week) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The row's dots redrawn as a mask, so the sweep lights exactly what the athlete earned
    /// (dot alpha carries the strain steps, so the shimmer inherits them).
    private func rowDots(_ week: [Day]) -> some View {
        HStack(spacing: 0) {
            ForEach(week) { day in
                dot(day).frame(width: cellSize, height: cellSize)
            }
        }
    }

    /// "2026-07-13" in the card's own calendar — the persisted once-per-week key suffix.
    private func isoDay(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func popoverBinding(_ day: Day) -> Binding<Bool> {
        Binding(
            get: { selectedDay == day.id },
            set: { shown in if !shown, selectedDay == day.id { selectedDay = nil } }
        )
    }

    private func a11yLabel(_ day: Day) -> String {
        let date = day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        if isKeptRest(day) { return "\(date): planned rest, kept" }
        if let strain = day.strain {
            return "\(date): strain \(strain.score), \(strain.band.rawValue.lowercased())"
        }
        return "\(date): no data"
    }
}

// MARK: - Earned-shimmer once-gate (§6 triggers 2–4)

/// The one-time gate shared by the Health segment's three milestone shimmers — balanced week
/// (`RhythmCard`), sleep-consistency milestone (`SleepCard`), first banked baseline
/// (`VitalsBoard`). Each key fires exactly once ever (persisted in UserDefaults), and no two
/// earned moments may start in the same beat — §6: never simultaneous. A claim refused by the
/// beat guard leaves its key unburned, so that moment simply lands on the next visit.
@MainActor
enum HealthShimmerGate {
    private static var lastClaimAt: Date = .distantPast
    /// Minimum spacing between any two earned shimmers (sweep length + a breath).
    private static let beat: TimeInterval = 2.0

    static func claim(_ key: String,
                      defaults: UserDefaults = .standard,
                      now: Date = .now) -> Bool {
        guard !defaults.bool(forKey: key),
              now.timeIntervalSince(lastClaimAt) >= beat else { return false }
        lastClaimAt = now
        defaults.set(true, forKey: key)
        return true
    }
}

// MARK: - Day summary popover (§11.2.6)

/// "Strain 62 — mostly the tempo, plus a 14k-step day": the day's number decomposed from the
/// engine's `workoutLoad`/`ambientLoad` split, in plain words. It only names what it knows —
/// no workout name means plain "training", no step count means "everyday movement".
private struct DaySummaryPopover: View {
    let day: RhythmCard.Day

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                .foregroundStyle(Theme.inkTertiary)
            Text(summary)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(minWidth: 160, maxWidth: 260, alignment: .leading)
    }

    private var summary: String {
        guard let strain = day.strain else {
            return day.isRestDayPlanned ? "Planned rest — banked." : "No data this day."
        }
        if strain.score < 25, day.isRestDayPlanned {
            return "Planned rest — banked. This is where the training gets built."
        }
        if strain.score == 0 {
            return "A quiet day — no measurable strain."
        }

        var line = "Strain \(strain.score)"
        let workout = day.workoutName ?? "training"
        // The ambient side earns a mention only when it genuinely moved the number (≈ 4k+ steps).
        let ambientWorthNaming = strain.ambientLoad >= 40

        if strain.workoutLoad >= strain.ambientLoad, strain.workoutLoad > 0 {
            line += " — mostly \(workout)"
            if ambientWorthNaming { line += ", plus \(ambientPhrase)" }
        } else if strain.ambientLoad > 0 {
            line += " — mostly \(ambientPhrase)"
            if strain.workoutLoad > 0 { line += ", plus \(workout)" }
        }
        return line + "."
    }

    private var ambientPhrase: String {
        if let steps = day.ambientSteps, steps >= 4_000 {
            return "a \(Int((steps / 1_000).rounded()))k-step day"
        }
        return "a busy day on your feet"
    }
}

// MARK: - Preview

#Preview("Rhythm — light") {
    RhythmCardPreview()
}

#Preview("Rhythm — dark") {
    RhythmCardPreview().preferredColorScheme(.dark)
}

private struct RhythmCardPreview: View {
    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)

        // Synthesize a month with hard/easy contrast, kept rest days, and one data hole —
        // ambient steps alone drive DayStrain through its real saturating curve.
        let days: [RhythmCard.Day] = (0..<28).reversed().map { ago in
            let date = cal.date(byAdding: .day, value: -ago, to: today)!
            if ago % 7 == 2 {
                return RhythmCard.Day(date: date, isRestDayPlanned: true)
            }
            if ago == 9 {
                return RhythmCard.Day(date: date)   // hole — no Health data that day
            }
            let steps = Double(2_000 + (ago * 3_137) % 26_000)
            let strain = DayStrain(workoutsToday: [], ambientSteps: steps, chronicLoad: 40,
                                   now: date, calendar: cal)
            return RhythmCard.Day(date: date, strain: strain,
                                  workoutName: ago % 5 == 0 ? "the tempo" : nil,
                                  ambientSteps: steps)
        }

        return ScrollView {
            RhythmCard(days: days, monotony: 1.2)
                .padding(Theme.Space.md)
        }
        .background(Theme.background)
    }
}
