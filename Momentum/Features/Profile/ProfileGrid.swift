import SwiftUI

/// Which face of the profile grid is showing.
enum ProfileGridTab: String, CaseIterable {
    case grid, highlights
    var icon: String { self == .grid ? "square.grid.3x3.fill" : "sparkles" }
    var label: String { self == .grid ? "Grid" : "Highlights" }
}

/// The segmented control that sits above the grid (the profile's `▦ Grid` / `✦ Highlights` toggle,
/// TikTok's grid/repost tabs re-cast). Scrolls with the content — it is not pinned. Keeps its own
/// background + bottom hairline so it reads as a divider between the profile header and the grid.
struct ProfileGridTabBar: View {
    @Binding var tab: ProfileGridTab
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ProfileGridTab.allCases, id: \.self) { t in
                Button {
                    // Reduce Motion: no underline slide / height animation — plain swap.
                    if reduceMotion { tab = t }
                    else { withAnimation(.easeOut(duration: 0.2)) { tab = t } }
                } label: {
                    VStack(spacing: Theme.Space.sm) {
                        Image(systemName: t.icon).font(.system(size: 16, weight: .semibold))
                        ZStack {
                            Color.clear.frame(height: 2)
                            if tab == t {
                                Capsule()
                                    .fill(t == .highlights ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "profileGridUnderline", in: underline)
                            }
                        }
                    }
                    .foregroundStyle(tab == t ? Theme.ink : Theme.inkTertiary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(tab == t ? [.isSelected] : [])
            }
        }
        .padding(.top, Theme.Space.md)
        .background(Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// The two faces below the tab bar: the mosaic of workout "posts" (Grid), or the athlete's body of
/// work — lifetime totals, discipline mix, consistency, and curated bests (Highlights). A tap on any
/// tile or a workout-backed highlight reports the workout id up so the parent opens the immersive pager.
struct ProfileGrid: View {
    let workouts: [Workout]
    let stats: ProfileStats
    /// The award shelf (recent wins + the closest next-ups) — the Highlights trophy case.
    let awardsShelf: AwardsShelf
    /// Content signature from the parent — invalidates the month/day memos on equal-count edits
    /// (a workout's sport or date changing), not just count changes.
    var dataKey: Int = 0
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto
    let tab: ProfileGridTab
    /// Workouts holding a current personal record — their tiles carry the earned iridescent mark
    /// (iridescence is achievement-only, so the grid quietly doubles as a trophy wall).
    var prWorkoutIds: Set<UUID> = []
    /// Called with the tapped workout's id.
    var onOpen: (UUID) -> Void
    /// Called when the athlete opens the full awards gallery.
    var onOpenAwards: () -> Void = {}

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm), count: 3)

    var body: some View {
        // The faces cross-dissolve with a small lift (transform-only) — the parent's withAnimation
        // on the tab drives it; Reduce Motion switches without animation upstream.
        switch tab {
        case .grid: gridContent.transition(.opacity.combined(with: .offset(y: 6)))
        case .highlights: highlightsContent.transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    // MARK: Grid — the training log as an editorial mosaic

    /// Months give the mosaic its rhythm: an endless undifferentiated wall reads as a dump; the
    /// same tiles under quiet month rules read as a body of work. Grouping walks every workout →
    /// memoized per data change (reference box — mutating it mid-body is invisible to SwiftUI).
    private struct MonthGroup: Identifiable {
        let id: Date          // month start
        let title: String     // "JULY" / "JULY 2025"
        let workouts: [Workout]
        let tileOffset: Int   // running tile index before this group — global entrance stagger
    }
    private final class MonthsMemo { var count = -1; var value: [MonthGroup] = [] }
    @State private var monthsMemo = MonthsMemo()
    private var monthGroups: [MonthGroup] {
        if monthsMemo.count != dataKey {
            let cal = Calendar.current
            let grouped = Dictionary(grouping: workouts) {
                cal.dateInterval(of: .month, for: $0.startedAt)?.start ?? $0.startedAt
            }
            var offset = 0
            monthsMemo.value = grouped.keys.sorted(by: >).map { start in
                let rows = grouped[start] ?? []
                defer { offset += rows.count }
                return MonthGroup(id: start, title: Self.monthTitle(start, calendar: cal),
                                  workouts: rows, tileOffset: offset)
            }
            monthsMemo.count = dataKey
        }
        return monthsMemo.value
    }

    private static func monthTitle(_ start: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: Date())
        formatter.dateFormat = sameYear ? "MMMM" : "MMMM yyyy"
        return formatter.string(from: start).uppercased()
    }

    private var gridContent: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
            Color.clear.frame(height: 0)
                .task {
                    // Retire the entrance once it has played (stagger + fade ≈ 0.9s).
                    try? await Task.sleep(for: .seconds(1.2))
                    didEntrance = true
                }
            ForEach(monthGroups) { group in
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    sectionRule(group.title, meta: "\(group.workouts.count)")
                    LazyVGrid(columns: columns, spacing: Theme.Space.sm) {
                        ForEach(Array(group.workouts.enumerated()), id: \.element.id) { i, workout in
                            tileCell(workout, globalIndex: group.tileOffset + i)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
    }

    /// The first screenful settles in with a quiet stagger; everything below appears instantly
    /// (an entrance fade on every scrolled-in row reads as lag, not polish). One-shot: after the
    /// entrance has played, recycled top cells scrolled back into view appear instantly too —
    /// `.reveal`'s per-cell @State resets on recycle and the top row re-fading read as a flash.
    @State private var didEntrance = false
    @ViewBuilder
    private func tileCell(_ workout: Workout, globalIndex: Int) -> some View {
        let tile = WorkoutTile(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit,
                               isPR: prWorkoutIds.contains(workout.id)) {
            onOpen(workout.id)
        }
        if globalIndex < 9 {
            tile.modifier(TileEntrance(delay: Double(globalIndex) * 0.035, enabled: !didEntrance))
        } else {
            tile
        }
    }

    // MARK: Highlights — the athlete's body of work

    private var highlightsContent: some View {
        // The signature reveal cascade (the summary screens' entrance): each block lands a beat
        // after the one above, so the page reads top-down as a composed report, not a dump.
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            lifetimeSection.reveal(0)
            if !stats.countsByType.isEmpty { trainSection.reveal(0.08) }
            consistencySection.reveal(0.16)
            awardsSection.reveal(0.24)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.lg)
    }

    /// The body of work as an editorial stat block, not a boxed strip: one hero number (distance —
    /// this is a running app) with the supporting totals hairline-divided beneath, set straight on
    /// the canvas. Rhymes with the identity trio above, so the whole page reads as one system.
    private var lifetimeSection: some View {
        section("Lifetime") {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    // The body of work tallies up as the page lands — the premium reveal every
                    // summary hero already uses, now on the athlete's whole story.
                    CountUpNumber(value: stats.totalDistanceM,
                                  format: { Formatters.distance(meters: $0, unit: distanceUnit) },
                                  font: .display(40, weight: .black))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .accessibilityLabel("Distance covered")
                        .accessibilityValue(Formatters.distance(meters: stats.totalDistanceM, unit: distanceUnit))
                    Text("distance covered")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                // A rule the page draws for itself — the editorial hairline between the headline
                // and its supporting figures.
                PenRule(delay: 0.3)
                HStack(spacing: 0) {
                    lifetimeCell(Formatters.duration(s: stats.totalDurationS), "Time moving")
                    lifetimeDivider
                    lifetimeCell("\(stats.totalWorkouts)", "Sessions")
                    if stats.totalVolumeKg > 0 {
                        let vol = weightUnit == .lb ? stats.totalVolumeKg * Formatters.lbPerKg : stats.totalVolumeKg
                        lifetimeDivider
                        lifetimeCell("\(Formatters.compact(vol)) \(weightUnit == .lb ? "lb" : "kg")", "Lifted")
                    }
                }
            }
        }
    }

    private func lifetimeCell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(18, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.8)
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lifetimeDivider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 30)
            .padding(.trailing, Theme.Space.md)
    }

    private var trainSection: some View {
        section("How you train") {
            DisciplineBreakdown(counts: stats.countsByType)
                .padding(Theme.Space.lg).background(card)
        }
    }

    /// Active minutes per local day — the consistency chart's intensity signal (a 20-minute jog
    /// and a two-hour long run are different days, and the chart should say so). Memoized per data
    /// change: `Calendar.ordinality` per workout is expensive and this re-ran on every Highlights
    /// body evaluation (the sibling walks in ProfileScreen cache for exactly this reason).
    private final class DayMinutesMemo { var count = -1; var value: [Int: Double] = [:] }
    @State private var dayMinutesMemo = DayMinutesMemo()
    private var dayMinutes: [Int: Double] {
        if dayMinutesMemo.count != dataKey {
            var out: [Int: Double] = [:]
            for w in workouts {
                out[StreakCalculator.localDay(w.startedAt), default: 0] += w.durationS / 60
            }
            dayMinutesMemo.count = dataKey
            dayMinutesMemo.value = out
        }
        return dayMinutesMemo.value
    }

    /// The GitHub-grade consistency graph: month axis, weekday hints, today ring — plus the one
    /// number that summarizes it, set as the card's own headline.
    private var consistencySection: some View {
        let today = StreakCalculator.localDay(Date())
        let active = (0..<(16 * 7)).filter { stats.countingDays.contains(today - $0) }.count
        return section("Consistency") {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    CountUpNumber(value: Double(active), format: { "\(Int($0.rounded()))" },
                                  font: .display(22, weight: .black), delay: 0.15)
                        .accessibilityLabel("Active days, last 16 weeks")
                        .accessibilityValue("\(active)")
                    Text("active days · last 16 weeks")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                ConsistencyHeatmap(countingDays: stats.countingDays,
                                   dayMinutes: dayMinutes, showsAxes: true)
            }
            .padding(Theme.Space.lg).background(card)
        }
        .id("profile-consistency")
    }

    private var awardsSection: some View {
        section("Awards", meta: "\(awardsShelf.earnedCount) of \(awardsShelf.totalCount)") {
            VStack(spacing: Theme.Space.md) {
                // The trophy case: three medallions to a row, floating on the canvas (a card around
                // a 3D medal would flatten it — the drop shadow needs the page to land on). Recent
                // wins in metal; the closest locked coins ghost in behind them as the chase. Each
                // coin settles onto the shelf with a small spring — entrance only, then static
                // (medallion grids must hold 60fps).
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm), count: 3),
                          spacing: Theme.Space.md) {
                    ForEach(Array(awardsShelf.cells.enumerated()), id: \.element.id) { i, cell in
                        AwardCell(award: cell.award, earnedAt: cell.earnedAt, progress: cell.progress)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpenAwards() }
                            .modifier(SettleIn(delay: 0.28 + Double(i) * 0.05))
                    }
                }
                Button(action: onOpenAwards) {
                    HStack(spacing: Theme.Space.sm) {
                        Text("All awards")
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(awardsShelf.earnedCount) of \(awardsShelf.totalCount)")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.inkTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                    .padding(Theme.Space.md)
                    .background(card)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All awards, \(awardsShelf.earnedCount) of \(awardsShelf.totalCount) earned")
            }
        }
        .id("profile-badges")
    }

    // MARK: Building blocks

    /// The editorial section header: a small tracked label with a hairline extending to the
    /// margin, and optional right-aligned meta ("6 of 82"). One header language across both
    /// faces — the month rules in the grid use the same form.
    private func sectionRule(_ title: String, meta: String? = nil) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text(title)
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let meta {
                Text(meta)
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize()
            }
        }
    }

    private func section<Content: View>(_ title: String, meta: String? = nil,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionRule(title.uppercased(), meta: meta)
            content()
        }
    }
    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }
}

// MARK: - Motion primitives (profile entrances — transform-only, Reduce Motion snaps)

/// A number that tallies up once when it appears. Shared by the lifetime hero and the
/// consistency headline; Reduce Motion shows the final value immediately.
private struct CountUpNumber: View {
    let value: Double
    let format: (Double) -> String
    var font: Font
    var delay: Double = 0
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AnimatedCounter(value: shown, format: format)
            .font(font)
            .foregroundStyle(Theme.ink)
            .onAppear {
                guard !reduceMotion else { shown = value; return }
                shown = 0
                withAnimation(.easeOut(duration: 0.7).delay(delay)) { shown = value }
            }
    }
}

/// A hairline the page draws for itself, left to right (scale transform, never layout).
private struct PenRule: View {
    var delay: Double = 0
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
            .scaleEffect(x: drawn || reduceMotion ? 1 : 0.001, anchor: .leading)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.pen(0.7).delay(delay)) { drawn = true }
            }
            .accessibilityHidden(true)
    }
}

/// The grid's one-shot entrance: fade + lift while `enabled`, instant forever after — a recycled
/// lazy cell must not replay its entrance when scrolled back into view.
private struct TileEntrance: ViewModifier {
    let delay: Double
    let enabled: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || !enabled || reduceMotion ? 1 : 0)
            .offset(y: shown || !enabled || reduceMotion ? 0 : 14)
            .onAppear {
                guard enabled, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.5).delay(delay)) { shown = true }
            }
    }
}

/// A small scale-spring settle for objects landing on a shelf (the award medallions).
private struct SettleIn: ViewModifier {
    var delay: Double = 0
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(settled || reduceMotion ? 1 : 0.92)
            .opacity(settled || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75).delay(delay)) {
                    settled = true
                }
            }
    }
}

// MARK: - Tile

/// One workout "post": full-bleed media (route map / muscle body / photo / glyph) with a minimal
/// metric strip over a bottom scrim. Portrait 3:4, rounded — dense but premium.
private struct WorkoutTile: View {
    let workout: Workout
    var weightUnit: WeightUnit
    var distanceUnit: DistanceUnit
    /// This workout holds a current PR → the tile carries the earned iridescent mark.
    var isPR: Bool = false
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { WorkoutTileMedia(workout: workout, style: .tile) }
                .overlay(alignment: .bottom) { metricStrip }
                .overlay(alignment: .topTrailing) { if isPR { prMark } }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(TilePressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(workout.type.title), \(metric)\(isPR ? ", personal record" : "")")
        .accessibilityAddTraits(.isButton)
    }

    /// The earned mark: a small iridescent dot, white-ringed so it reads on any basemap or photo.
    /// Achievement-only iridescence (brand rule) — most tiles stay quiet, records glint.
    private var prMark: some View {
        Circle()
            .fill(IridescentMaterial())
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
            .padding(7)
    }

    private var metricStrip: some View {
        HStack(spacing: 4) {
            Image(systemName: workout.type.systemImage).font(.system(size: 10, weight: .bold))
            // The number is the tile's voice — it speaks in the display face, like every hero.
            Text(metric).font(.display(11.5, weight: .heavy)).monospacedDigit()
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            Spacer(minLength: 4)
            // A quiet date turns the mosaic into a legible training log at a glance.
            Text(workout.startedAt, format: .dateTime.month(.abbreviated).day())
                .font(.rounded(9.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.72))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Space.sm).padding(.vertical, Theme.Space.chipV)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A longer, softer editorial fade — the metric floats on the photo instead of sitting
        // on a hard band.
        .background(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.16), location: 0.45),
            .init(color: .black.opacity(0.52), location: 1),
        ], startPoint: .top, endPoint: .bottom).padding(.top, -Theme.Space.lg))
    }

    private var metric: String {
        if workout.type.isStrengthStyle, let s = workout.strength {
            let vol = weightUnit == .lb ? s.totalVolumeKg * Formatters.lbPerKg : s.totalVolumeKg
            return "\(Formatters.compact(vol)) \(weightUnit == .lb ? "lb" : "kg")"
        } else if workout.type.isGPS, let gps = workout.gps, gps.distanceM > 0 {
            return Formatters.distance(meters: gps.distanceM, unit: distanceUnit)
        }
        return Formatters.duration(s: workout.durationS)
    }
}

/// Tile press feedback: a small transform-only settle (brand rule: animate transforms, never
/// layout) so the mosaic feels tactile without any chrome.
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

