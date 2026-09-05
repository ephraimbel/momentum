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
                                    // Selected-tab underline in lavender (rebrand 2026-08-16);
                                    // highlights keeps the earned iridescent exception.
                                    .fill(t == .highlights ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.purple))
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
    /// When set, each tile registers as the zoom source for the pager (see ProfileScreen). Optional
    /// with a nil default so previews and any other host keep building unchanged.
    var zoomNamespace: Namespace.ID? = nil

    /// The gutter is a HAIRLINE, not a spacing token (Instagram measures 1px; we use 2pt so it
    /// survives dark mode and non-Retina scaling). This is the single biggest reason a photo grid
    /// reads as "a wall of work" rather than "cards on a page": at 2pt, ~99% of each row's width is
    /// image, and the gap carries no rhythm or grouping — it exists only to stop two adjacent tiles
    /// bleeding into each other. Tile corner radius is 0 as a direct CONSEQUENCE: at this gutter,
    /// even a 4pt radius opens a visible four-pointed star of page background at every junction.
    static let gutter = 2.0
    private let columns = Array(repeating: GridItem(.flexible(), spacing: ProfileGrid.gutter), count: 3)

    var body: some View {
        // The faces cross-dissolve with a small lift (transform-only) — the parent's withAnimation
        // on the tab drives it; Reduce Motion switches without animation upstream.
        switch tab {
        case .grid: gridContent.transition(.opacity.combined(with: .offset(y: 6)))
        case .highlights: highlightsContent.transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    // MARK: Grid — one continuous mosaic

    /// No month rules (owner call 2026-07-28). They were there to give the wall a rhythm, but
    /// Instagram's grid has no section breaks at all, and once the tiles went edge to edge the
    /// rules read as chrome cutting the work into pages. `workouts` arrives newest-first from the
    /// parent's `@Query`, so the mosaic is already in the right order; the date each tile belongs
    /// to lives on its detail page.
    private var gridContent: some View {
        LazyVGrid(columns: columns, spacing: ProfileGrid.gutter) {
            ForEach(Array(workouts.enumerated()), id: \.element.id) { i, workout in
                tileCell(workout, globalIndex: i)
            }
        }
        // Edge to edge horizontally; the first row sits one gutter under the tab strip's hairline,
        // so the grid reads as a continuation of it rather than a separate block.
        .padding(.top, ProfileGrid.gutter)
        .task {
            // Retire the entrance once it has played (stagger + fade ≈ 0.9s).
            try? await Task.sleep(for: .seconds(1.2))
            didEntrance = true
        }
    }

    /// The first screenful settles in with a quiet stagger; everything below appears instantly
    /// (an entrance fade on every scrolled-in row reads as lag, not polish). One-shot: after the
    /// entrance has played, recycled top cells scrolled back into view appear instantly too —
    /// `.reveal`'s per-cell @State resets on recycle and the top row re-fading read as a flash.
    @State private var didEntrance = false
    @ViewBuilder
    private func tileCell(_ workout: Workout, globalIndex: Int) -> some View {
        let bare = WorkoutTile(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit,
                               isPR: prWorkoutIds.contains(workout.id)) {
            onOpen(workout.id)
        }
        // Zoom source keyed on the workout id — the pager's `.zoom` grows out of exactly this
        // tile. Applied per-cell rather than on the grid so recycling keeps ids honest.
        let tile = Group {
            if let ns = zoomNamespace {
                bare.matchedTransitionSource(id: workout.id, in: ns)
            } else {
                bare
            }
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
            lifetimeSection.reveal(0, once: "profile.lifetime")
            if !stats.countsByType.isEmpty { trainSection.reveal(0.02, once: "profile.training") }
            consistencySection.reveal(0.04, once: "profile.consistency")
            awardsSection.reveal(0.06, once: "profile.awards")
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
        Color.clear.raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

// MARK: - Motion primitives (profile entrances — transform-only, Reduce Motion snaps)

/// A number that tallies up once when it appears. Shared by the lifetime hero and the
/// consistency headline; Reduce Motion shows the final value immediately. Internal, not private:
/// visited athlete profiles (AthleteProfileView) run the SAME Highlights motion — one profile
/// grammar app-wide (owner call 2026-07-30).
struct CountUpNumber: View {
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
/// Internal for the same reason as `CountUpNumber` — the visited-profile Highlights shares it.
struct PenRule: View {
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
/// Internal like `CountUpNumber`/`PenRule` — the visited-profile trophy case shares it.
struct SettleIn: ViewModifier {
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

/// One workout "post": full-bleed media (route map / muscle body / photo / glyph) under a single
/// quiet number. Portrait 3:4, SQUARE-cornered, borderless, hairline-gutter — the Instagram grid
/// read (2026-07-28): uniform shape, no chrome, media edge to edge.
///
/// The one thing we keep that Instagram drops is the metric. A photo grid can be text-free because
/// the photo IS the content; here most tiles are grey route lines, and without the number a
/// 3-mile shakeout and a 20-mile long run are the same picture. So: the number stays, the sport
/// icon, the date and the heavy scrim go (owner call 2026-07-28).
private struct WorkoutTile: View {
    let workout: Workout
    var weightUnit: WeightUnit
    var distanceUnit: DistanceUnit
    /// This workout holds a current PR → the tile carries the earned iridescent mark.
    var isPR: Bool = false
    var onOpen: () -> Void

    /// Which canvas the media layer actually drew — drives `metricInk`. Defaults to the
    /// Theme-backed case, which is what the brief placeholder before resolve is too.
    @State private var ink: WorkoutTileMedia.InkContext = .appearance

    var body: some View {
        Button(action: onOpen) {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { WorkoutTileMedia(workout: workout, style: .tile, onInkContext: { ink = $0 }) }
                .overlay(alignment: .bottom) { metricStrip }
                .overlay(alignment: .topTrailing) { if isPR { prMark } }
                // Square + borderless. Both are required by the hairline gutter: a radius would
                // punch background stars into every junction, and a stroke on a 2pt gutter reads
                // as a 4pt double line between neighbours.
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(TilePressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(workout.type.title), \(metric)\(isPR ? ", personal record" : "")")
        .accessibilityHint("Opens the activity full screen. Swipe up or down for more.")
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

    /// One number, bottom-left. No sport icon, no date, no band — those three were what made the
    /// mosaic read as a stack of labelled cards instead of a wall of work.
    ///
    /// The scrim went with them, which means legibility has to come from the ink — over five very
    /// different canvases. Rather than guess the backdrop, the media layer reports which one it
    /// drew (`onInkContext`), so each tile picks ink that's right by construction and re-picks if
    /// the snapshot heal swaps the canvas mid-flight.
    private var metricStrip: some View {
        Text(metric)
            .font(.display(11.5, weight: .heavy)).monospacedDigit()
            .foregroundStyle(metricInk)
            // A photo is the only unknown canvas, so it's the only one that needs a halo. On our own
            // canvases the ink already contrasts and a shadow would read as a smudge on a clean map.
            // Structurally absent when inactive — a 0-opacity shadow still pays its offscreen pass,
            // twice per tile across the whole scrolling grid (perf audit 2026-08-13).
            .modifier(PhotoLegibilityShadow(active: ink == .photo))
            .padding(.horizontal, 7).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricInk: Color {
        switch ink {
        case .fixedLight: Theme.inkOnFixedLight   // route snapshot: a light basemap in BOTH appearances
        case .appearance: Theme.ink               // muscle / silhouette / glyph: Theme-backed canvas
        case .photo:      .white                  // unknown canvas: white, carried by the halo above
        }
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

/// Tile press feedback: dim only.
///
/// The scale-down had to go with the gutter. At 8pt gaps a 0.97 shrink read as a tactile settle;
/// at 2pt it opens a visible hole around the pressed tile and the mosaic looks like it glitched.
/// Instagram dims for the same reason. Still transform-only (opacity), still Reduce-Motion-safe.
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
