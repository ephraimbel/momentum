import SwiftUI
import PhotosUI
import CoreLocation
import SwiftData

/// The post-activity page's full-bleed hero (user call 2026-08-14): the activity's identity
/// visual runs edge-to-edge from the very top of the screen and DISSOLVES into the page — a
/// gradient of `Theme.background` melts its lower third, so the title and stats below read as
/// printed over the tail of the scene, not stacked under a card.
///
/// One component, every discipline:
/// - a run/ride/hike with a route → the map (tap → the full-screen explorable map, the same
///   zoom transition and chrome the card version had),
/// - a lifting session → the worked body, lit,
/// - a timed sport, or a hand-logged workout with no trace → the sport's glyph on a quiet band.
///
/// The camera chip (bottom-trailing) attaches photos from the library straight onto the
/// workout — the fastest path from "just finished" to "the photo's on it"; the photo section
/// lower on the page stays the place to manage them.
struct ActivityHero: View {
    let workout: Workout
    /// Live style override from the save editor's map-style row (nil = the workout's own).
    var mapStyleOverride: MapStyleOption? = nil
    var canAddPhotos: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            media
            if canAddPhotos { HeroCameraChip(workout: workout) }
        }
        // Exactly the scroll container's width, never wider (2026-08-14): the map's intrinsic
        // size could exceed the viewport, which let the whole page drift sideways under a
        // horizontal swipe — the "wobbly, uncentered" feel. Clamp and clip; the page only
        // ever moves vertically.
        .containerRelativeFrame(.horizontal)
        .clipped()
    }

    @ViewBuilder
    private var media: some View {
        if let gps = workout.gps, workout.type.isGPS {
            HeroMap(gps: gps, type: workout.type, style: mapStyleOverride ?? gps.mapStyle)
        } else if workout.type.isStrengthStyle, let session = workout.strength {
            HeroMuscleFigure(session: session)
        } else {
            HeroGlyphBand(type: workout.type)
        }
    }
}

/// The dissolve: media fades into the page so content below sits IN the scene's tail.
private struct HeroFade: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: .clear, location: 0.45),
                               .init(color: Theme.background.opacity(0.55), location: 0.78),
                               .init(color: Theme.background, location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }
}

// MARK: - Map hero (runs, rides, hikes)

/// Full-bleed twin of the old `RouteMapCard`, same contract: self-contained leaf (a tap
/// invalidates only this view, not the page), remount keyed on match-presence + style, the
/// zoom transition into `RunMapFullScreen`, and the same accessibility labels the regression
/// test pins.
private struct HeroMap: View {
    let gps: GPSDetail
    let type: WorkoutType
    let style: MapStyleOption

    /// Resolved ONCE off the samples (the full Kalman replay) — never in `body`.
    @State private var smoothedCoords: [CLLocationCoordinate2D] = []
    @State private var routeResolved = false
    @State private var showFullMap = false
    @Namespace private var mapZoom

    var body: some View {
        Group {
            if smoothedCoords.count > 1 {
                RouteMapView(coordinates: smoothedCoords, style: style,
                             insets: ActivityHeroMetrics.routeInsets)
                    .frame(height: ActivityHeroMetrics.mapHeight)
                    // Remount ONLY when the map-matched route lands (the line's source holds the
                    // old coordinates otherwise). A style change deliberately does NOT remount
                    // (2026-08-14): `RouteMapView` swaps styles in place — `.mapStyle` reloads the
                    // basemap in the same view and `onStyleLoaded` re-adds the route — so the
                    // camera and tiles hold instead of flashing through a blank rebuild.
                    .id(gps.matchedRouteData != nil)
                    .overlay(HeroFade())
                    .overlay(alignment: .bottomLeading) {
                        Image(systemName: "arrow.down.left.and.arrow.up.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Theme.background.opacity(0.92)))
                            .overlay(Circle().stroke(Theme.hairline))
                            .padding(Theme.Space.lg)
                    }
                    .contentShape(Rectangle())
                    .matchedTransitionSource(id: "runMap", in: mapZoom)
                    .onTapGesture { showFullMap = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Route map. Opens full screen.")
                    .fullScreenCover(isPresented: $showFullMap) {
                        RunMapFullScreen(coordinates: smoothedCoords, style: style,
                                         onClose: { showFullMap = false })
                            .navigationTransition(.zoom(sourceID: "runMap", in: mapZoom))
                    }
            } else if !routeResolved {
                // Hold the footprint quietly while the replay resolves — flashing the glyph
                // band over every real route for one beat read as a missing map.
                Theme.surface.frame(height: ActivityHeroMetrics.mapHeight)
                    .overlay(HeroFade())
            } else {
                // Treadmill / GPS never locked — the sport's glyph carries the identity.
                HeroGlyphBand(type: type, caption: "No route recorded")
            }
        }
        // Re-keyed when the map-matched route lands post-finish, so the snapped line
        // supersedes the raw one (the old summary-level task, now owned by the hero).
        .task(id: gps.matchedRouteData != nil) {
            let coords = gps.routeCoordinates(type: type)
            smoothedCoords = coords.count > 1 ? RouteSmoothing.smooth(coords) : []
            routeResolved = true
        }
    }
}

// MARK: - Muscle hero (lifting)

private struct HeroMuscleFigure: View {
    let session: StrengthSession
    /// Frozen once scrolled past (the AthletePanel pattern) — the mesh must not animate
    /// under the whole page visit.
    @State private var onScreen = true

    var body: some View {
        let entries = session.exercises.map { row in
            (primary: (row.exercise?.primaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             secondary: (row.exercise?.secondaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             sets: row.sets.filter { $0.isComplete && $0.type == .working }.count)
        }
        return ZStack {
            Theme.surface
            MuscleMapView(activation: StrengthMath.weeklySetsByMuscle(entries), forceStatic: !onScreen)
                .padding(.top, 54)          // clear the status bar + floating chrome
                .padding(.bottom, 46)       // keep the feet above the dissolve
        }
        .frame(height: ActivityHeroMetrics.muscleHeight)
        .overlay(HeroFade())
        .onScrollVisibilityChange(threshold: 0.05) { onScreen = $0 }
        .accessibilityLabel("Muscles worked this session")
    }
}

// MARK: - Glyph hero (timed sports, route-less logs)

private struct HeroGlyphBand: View {
    let type: WorkoutType
    var caption: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: Theme.Space.sm) {
                // The Today deck's map-less identity mark (owner ask 2026-07-30, reused here
                // 2026-08-14): the sport's glyph floating over a soft iridescent halo — the
                // brand's five hues blurred until they read as light behind the mark. Earned:
                // it only ever backs a completed activity. Static (Reduce Motion safe);
                // saturation/opacity tuned per scheme so it breathes on white and doesn't
                // curdle on warm charcoal.
                Image(systemName: type.systemImage)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 140, height: 140)
                    .background {
                        Circle()
                            .fill(AngularGradient(colors: Theme.iridescent + [Theme.iridescent[0]],
                                                  center: .center))
                            .frame(width: 155, height: 155)
                            .blur(radius: 36)
                            .saturation(colorScheme == .dark ? 2.6 : 1.25)
                            .opacity(colorScheme == .dark ? 0.38 : 0.8)
                    }
                if let caption {
                    Text(caption)
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(.top, 40)              // optically centre below the status bar
        }
        .frame(height: ActivityHeroMetrics.glyphHeight)
        .accessibilityHidden(true)
    }
}

enum ActivityHeroMetrics {
    static let mapHeight: CGFloat = 460

    /// Room to leave around the route in the hero.
    ///
    /// The hero runs full-bleed UNDER the floating chrome — the safe area plus the back / ⋯ /
    /// Done / Edit / Share controls on top, the fade and the expand chip at the bottom — so the
    /// frame is bigger than the part of it an athlete can actually see the route in. An even inset
    /// centred the loop in the FRAME and left its top arc behind the buttons (reported 2026-08-22:
    /// "we should be able to see the entire loop"). The heavier top inset moves the centre down by
    /// half the top/bottom difference; the wider sides stop a loop from grazing the screen edges,
    /// which is the other half of "I can see it fits, but only just".
    static let routeInsets = EdgeInsets(top: 112, leading: 34, bottom: 52, trailing: 34)
    static let muscleHeight: CGFloat = 380
    static let glyphHeight: CGFloat = 260

}

// MARK: - Camera chip

/// The one-tap "put the photo on it" affordance, floating on the hero. Library only — the
/// deliberate quick path (the photo you want is almost always the one you already took);
/// the photo section below still offers the camera.
private struct HeroCameraChip: View {
    @Bindable var workout: Workout
    @Environment(\.modelContext) private var context
    @State private var picked: [PhotosPickerItem] = []

    private var remaining: Int { Workout.photoCap - workout.orderedPhotosData.count }

    var body: some View {
        PhotosPicker(selection: $picked, maxSelectionCount: max(0, remaining), matching: .images) {
            Image(systemName: "camera.fill")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().stroke(Theme.hairline))
        }
        .disabled(remaining <= 0)
        .padding(Theme.Space.lg)
        .accessibilityLabel("Add photos from your library")
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await attach(items) }
        }
    }

    /// Same pipeline as `WorkoutPhotoSection`: downscale, append in order, re-dirty sync.
    private func attach(_ items: [PhotosPickerItem]) async {
        var order = (workout.photos.map(\.order).max() ?? -1) + 1
        for item in items.prefix(max(0, remaining)) {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            workout.photos.append(WorkoutPhoto(order: order, data: WorkoutPhotoSection.downscaled(data)))
            order += 1
        }
        picked = []
        // A photo added here can land on an already-published post — mark it for re-publish, not
        // just re-sync.
        SocialSyncEngine.markEdited(workout)
        try? context.save()
        Haptics.success()
    }
}

// MARK: - Save-screen chrome

/// The floating chrome every save screen wears over its hero — the navigation bar is hidden so
/// the scene owns the top of the screen. Overflow menu left, Done right, in the full-screen
/// map's surface-circle grammar.
struct SaveScreenChrome<MenuItems: View>: View {
    let onDone: () -> Void
    var doneDisabled: Bool = false
    /// True once the page has scrolled — a background scrim materializes under the chrome so
    /// content sliding beneath the physical top fades out instead of colliding with the clock.
    /// At rest it stays invisible: the hero owns the top of the screen, unwashed.
    var showsScrim: Bool = false
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        chromeRow
            .background(alignment: .top) {
                LinearGradient(colors: [Theme.background.opacity(0.96),
                                        Theme.background.opacity(0.85),
                                        Theme.background.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
                    .ignoresSafeArea(edges: .top)
                    .opacity(showsScrim ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }

    private var chromeRow: some View {
        HStack {
            Menu { menuItems() } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
            }
            .accessibilityLabel("More options")
            Spacer()
            Button { onDone() } label: {
                Text("Done")
                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Space.lg)
                    .frame(height: 36)
                    .background(Capsule().fill(Theme.surface)).overlay(Capsule().stroke(Theme.hairline))
            }
            .disabled(doneDisabled)
            // This chrome row replaced the save screen's navigation bar, so `navigationBars
            // .buttons["Done"]` stopped resolving and took 3 UI suites down with it
            // (CelebrationFlow, CoreRunFlow, TimedSave). Tests target this identifier now — it
            // survives the next visual pass in a way a bar lookup or a bare label never will.
            .accessibilityIdentifier("activityDone")
        }
        .padding(.horizontal, Theme.Space.lg)
    }
}

/// "RUN · Thursday, Aug 14 at 6:12" — the eyebrow above the editable title, naming the sport
/// and the moment (the hidden navigation bar used to carry the sport's name).
struct ActivityEyebrow: View {
    let type: WorkoutType
    let date: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: type.systemImage)
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
            Text(type.title.uppercased()).tracking(1.2)
            Text("·")
            Text(date.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
        }
        .font(.rounded(Theme.FontSize.label, weight: .bold))
        .foregroundStyle(Theme.inkTertiary)
        .lineLimit(1).minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Key stats

/// One organized reading of the session's numbers (user call 2026-08-14, the reference's "Key
/// Stats" block): a labelled two-column grid — small-caps label over a big tabular value —
/// replacing the cramped single row that squeezed five stats shoulder to shoulder.
struct KeyStat: Identifiable {
    let id: String
    let value: String
    let label: String
    init(_ value: String, _ label: String) { self.id = label; self.value = value; self.label = label }
}

struct KeyStatsGrid: View {
    let stats: [KeyStat]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("KEY STATS")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stat.label.uppercased())
                            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                            .foregroundStyle(Theme.inkTertiary)
                        Text(stat.value)
                            .font(.display(24, weight: .heavy)).monospacedDigit()
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(stat.label), \(stat.value)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Full-screen route map

/// The hero map, expanded (moved here from CardioSummaryView with the hero, 2026-08-14): the
/// whole route on an explorable full-bleed canvas. Chrome follows the immersive pager's
/// grammar; close is HOST-OWNED (`@Environment(\.dismiss)` silently did nothing from inside
/// this zoom-transition cover nested in the post-run presentation stack — verified on-sim).
struct RunMapFullScreen: View {
    let coordinates: [CLLocationCoordinate2D]
    let style: MapStyleOption
    let onClose: () -> Void
    @State private var camera = RouteMapCameraHandle()

    var body: some View {
        ZStack(alignment: .top) {
            RouteMapView(coordinates: coordinates, style: style,
                         interactive: true, padding: 56, cameraHandle: camera)
                .ignoresSafeArea()
            HStack(alignment: .top) {
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
                }
                .accessibilityLabel("Close map")
                Spacer()
                if camera.isExplored {
                    Button { camera.recenter() } label: {
                        Image(systemName: "viewfinder").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
                    }
                    .accessibilityLabel("Re-center route")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.easeOut(duration: 0.25), value: camera.isExplored)
            .padding(.horizontal, Theme.Space.lg)
        }
        .background(Theme.background)
    }
}
