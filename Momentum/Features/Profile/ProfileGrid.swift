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
                WorkoutTile(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit) {
                    onOpen(workout.id)
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
    }

    // MARK: Highlights — the athlete's body of work

    private var highlightsContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            lifetimeSection
            if !stats.countsByType.isEmpty { trainSection }
            consistencySection
            if !highlights.items.isEmpty { bestsSection }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
    }

    private var lifetimeSection: some View {
        var cells: [StatGrid.Cell] = [
            .init(value: Formatters.distance(meters: stats.totalDistanceM, unit: distanceUnit), label: "Distance"),
            .init(value: Formatters.duration(s: stats.totalDurationS), label: "Time"),
        ]
        if stats.totalVolumeKg > 0 {
            let vol = weightUnit == .lb ? stats.totalVolumeKg * Formatters.lbPerKg : stats.totalVolumeKg
            cells.append(.init(value: "\(Formatters.compact(vol)) \(weightUnit == .lb ? "lb" : "kg")", label: "Volume"))
        }
        return section("Lifetime") {
            StatGrid(cells: cells, valueSize: 18).padding(.vertical, Theme.Space.md).background(card)
        }
    }

    private var trainSection: some View {
        section("How you train") {
            DisciplineBreakdown(counts: stats.countsByType).padding(Theme.Space.md).background(card)
        }
    }

    private var consistencySection: some View {
        section("Consistency") {
            ConsistencyHeatmap(countingDays: stats.countingDays).padding(Theme.Space.md).background(card)
        }
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
    var onOpen: () -> Void

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay { WorkoutTileMedia(workout: workout, style: .tile) }
            .overlay(alignment: .bottom) { metricStrip }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(workout.type.title), \(metric)")
            .accessibilityAddTraits(.isButton)
    }

    private var metricStrip: some View {
        HStack(spacing: 4) {
            Image(systemName: workout.type.systemImage).font(.system(size: 10, weight: .bold))
            Text(metric).font(.rounded(11, weight: .bold)).monospacedDigit()
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

