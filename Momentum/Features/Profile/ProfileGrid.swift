import SwiftUI

/// Which face of the profile grid is showing.
enum ProfileGridTab: String, CaseIterable {
    case grid, highlights
    var icon: String { self == .grid ? "square.grid.3x3.fill" : "sparkles" }
    var label: String { self == .grid ? "Grid" : "Highlights" }
}

/// The pinned segmented control that sits above the grid (the profile's `▦ Grid` / `✦ Highlights`
/// toggle, TikTok's grid/repost tabs re-cast). Opaque background so scrolling tiles hide beneath it.
struct ProfileGridTabBar: View {
    @Binding var tab: ProfileGridTab
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ProfileGridTab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { tab = t }
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
    let highlights: ProfileHighlights
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto
    let tab: ProfileGridTab
    /// Workouts holding a current personal record — their tiles carry the earned iridescent mark
    /// (iridescence is achievement-only, so the grid quietly doubles as a trophy wall).
    var prWorkoutIds: Set<UUID> = []
    /// Called with the tapped workout's id.
    var onOpen: (UUID) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm), count: 3)

    var body: some View {
        switch tab {
        case .grid: gridContent
        case .highlights: highlightsContent
        }
    }

    // MARK: Grid

    private var gridContent: some View {
        LazyVGrid(columns: columns, spacing: Theme.Space.sm) {
            ForEach(workouts) { workout in
                WorkoutTile(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit,
                            isPR: prWorkoutIds.contains(workout.id)) {
                    onOpen(workout.id)
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
    }

    // MARK: Highlights — the athlete's body of work

    private var highlightsContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            lifetimeSection
            if !stats.countsByType.isEmpty { trainSection }
            consistencySection
            if !highlights.items.isEmpty { bestsSection }
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
                    Text(Formatters.distance(meters: stats.totalDistanceM, unit: distanceUnit))
                        .font(.display(40, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("distance covered")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
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
    /// and a two-hour long run are different days, and the chart should say so).
    private var dayMinutes: [Int: Double] {
        var out: [Int: Double] = [:]
        for w in workouts {
            out[StreakCalculator.localDay(w.startedAt), default: 0] += w.durationS / 60
        }
        return out
    }

    /// The GitHub-grade consistency graph: month axis, weekday hints, today ring — plus the one
    /// number that summarizes it, set as the card's own headline.
    private var consistencySection: some View {
        let today = StreakCalculator.localDay(Date())
        let active = (0..<(16 * 7)).filter { stats.countingDays.contains(today - $0) }.count
        return section("Consistency") {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(active)").font(.display(22, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
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

    private var bestsSection: some View {
        section("Badges") {
            // The trophy case: three medallions to a row, floating on the canvas (a card around a
            // 3D medal would flatten it — the drop shadow needs the page to land on).
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm), count: 3),
                      spacing: Theme.Space.md) {
                ForEach(highlights.items) { item in
                    BadgeCell(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { if let id = item.workoutID { onOpen(id) } }
                }
            }
        }
        .id("profile-badges")
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(title).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            content()
        }
    }
    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
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
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
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
            Text(metric).font(.rounded(11, weight: .bold)).monospacedDigit()
            Spacer(minLength: 4)
            // A quiet date turns the mosaic into a legible training log at a glance.
            Text(workout.startedAt, format: .dateTime.month(.abbreviated).day())
                .font(.rounded(9.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.72))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Space.sm).padding(.vertical, Theme.Space.chipV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
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

