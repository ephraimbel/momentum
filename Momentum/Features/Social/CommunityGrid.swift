import SwiftUI
import UIKit
import CoreLocation

/// The Community face's mosaic (owner call 2026-07-29): the feed re-cast in the profile grid's own
/// language — 3-across, 2pt hairline gutters, square corners, media edge to edge — so Profile and
/// Community read as the SAME surface showing different people's work. Browsing density is the
/// point: a wall of routes/photos/lifts you scan and dive into, not a card feed you trudge through.
/// Order stays strictly reverse-chronological — the grid changes presentation, never the ethos.
struct CommunityFeedGrid: View {
    let items: [FeedItem]
    /// When set, each tile registers as the zoom source for the community pager.
    var zoomNamespace: Namespace.ID? = nil
    /// Fires with a tile's index as it scrolls into view — the wall's continuous-scroll prefetch
    /// hook (a near-end index means "the athlete is approaching the bottom, page more in NOW").
    /// nil for hosts that show a fixed set (athlete profiles).
    var onTileAppear: ((Int) -> Void)? = nil
    /// Called with the tapped post's id.
    var onOpen: (UUID) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: ProfileGrid.gutter), count: 3)

    /// One quiet arrival for the whole wall — a single fade + lift, ONCE PER SESSION. The profile
    /// grid's per-tile stagger was tried here first and is fragile against the snapshot render
    /// burst a cold community launch fires: nine delayed animation transactions competing with
    /// Mapbox's main-thread traffic stranded individual tiles translucent (2026-07-29). And the
    /// slider re-creates this view on every face switch — replaying the entrance each return read
    /// as a glitch, not a welcome (owner report, same day), so it plays on the first wall of the
    /// session and never again.
    @MainActor private static var didPlayEntrance = false
    @State private var arrived: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(items: [FeedItem], zoomNamespace: Namespace.ID? = nil,
         onTileAppear: ((Int) -> Void)? = nil, onOpen: @escaping (UUID) -> Void) {
        self.items = items
        self.zoomNamespace = zoomNamespace
        self.onTileAppear = onTileAppear
        self.onOpen = onOpen
        _arrived = State(initialValue: Self.didPlayEntrance)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: ProfileGrid.gutter) {
            // Indexed so a lazily-realized tile can report WHERE in the wall it is (the
            // continuous-scroll prefetch); identity stays the item id, so diffing is unchanged.
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                tileCell(item)
                    .onAppear { onTileAppear?(index) }
            }
        }
        .padding(.top, ProfileGrid.gutter)
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : 12)
        .onAppear {
            guard !arrived else { return }
            Self.didPlayEntrance = true
            if reduceMotion { arrived = true }
            else { withAnimation(.easeOut(duration: 0.45)) { arrived = true } }
        }
    }

    @ViewBuilder
    private func tileCell(_ item: FeedItem) -> some View {
        let bare = FeedTile(item: item) { onOpen(item.id) }
            .id(item.id)   // ScrollViewReader anchor (the --wall-scroll verification hook)
        if let ns = zoomNamespace {
            bare.matchedTransitionSource(id: item.id, in: ns)
        } else {
            bare
        }
    }
}

/// One community post as a grid tile: full-bleed media under a single quiet number — the exact
/// `WorkoutTile` read, driven by a `FeedItem` instead of a SwiftData workout. Media priority
/// mirrors the profile's: photo → muscle map → route → sport glyph.
private struct FeedTile: View {
    let item: FeedItem
    var onOpen: () -> Void

    @Environment(ReactionStore.self) private var reactions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ink: FeedTileMedia.InkContext = .appearance
    /// The double-tap heart burst — visible for a beat, then gone.
    @State private var burst = false

    var body: some View {
        Button(action: onOpen) {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { FeedTileMedia(item: item, onInkContext: { ink = $0 }) }
                .overlay(alignment: .bottom) { metricStrip }
                .overlay(alignment: .bottomTrailing) { avatarChip }
                .overlay(alignment: .topTrailing) { if item.prBadge != nil { prMark } }
                .overlay {
                    if burst {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedTilePressStyle())
        // Double-tap respects straight from the wall (the Instagram muscle memory). High priority
        // so it wins over the button's single tap — the ~quarter-second the single tap waits to
        // disambiguate is the standard trade every double-tappable feed makes. IG semantics: a
        // double-tap only ever ADDS respect; un-respecting lives in the pager.
        .highPriorityGesture(TapGesture(count: 2).onEnded { doubleTapRespect() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.authorName), \(item.title), \(item.statLine)")
        .accessibilityAddTraits(.isButton)
    }

    private func doubleTapRespect() {
        if !reactions.hasReacted(item.id) {
            reactions.toggle(item.id)
            Haptics.success()
        } else {
            Haptics.light()
        }
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { burst = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) { burst = false }
        }
    }

    /// A whisper of WHO, bottom-right (owner call 2026-07-29): with thousands of strangers on
    /// the wall, a 20pt avatar is what makes it read as people rather than wallpaper. Ringed in
    /// white so it lifts off any media; the metric keeps the bottom-left.
    private var avatarChip: some View {
        AvatarView(photo: item.avatarData, name: item.authorName, size: 20,
                   imageName: item.communityAvatarAsset, preset: item.communityPreset)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 0.5)
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)   // the tile's label already carries the author
    }

    /// The earned mark, same as the profile grid: a small iridescent dot for a PR post.
    private var prMark: some View {
        Circle()
            .fill(IridescentMaterial())
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
            .padding(7)
    }

    private var metricStrip: some View {
        // Shadows only on photo tiles: a zero-opacity `.shadow` still allocates its offscreen
        // render pass, and two of them per tile made every scrolled frame of the 3-across wall
        // pay ~24 dead passes (perf audit 2026-08-13).
        Text(metric)
            .font(.display(11.5, weight: .heavy)).monospacedDigit()
            .foregroundStyle(metricInk)
            .modifier(PhotoLegibilityShadow(active: ink == .photo))
            .padding(.horizontal, 7).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricInk: Color {
        switch ink {
        case .fixedLight: Theme.inkOnFixedLight
        case .appearance: Theme.ink
        case .photo:      .white
        }
    }

    /// One number per tile — the first (leading) metric of the post's stat line: distance for
    /// runs/rides, volume for lifts, time otherwise. Same "the number stays, everything else goes"
    /// rule as the profile grid.
    private var metric: String { item.metrics.first?.value ?? item.statLine }
}

/// The tile's media layer. Unlike `WorkoutTileMedia` there is no SwiftData walk here — a `FeedItem`
/// already carries its media inline — so resolution is just async image work: photo thumbnails
/// decode off-main, and route posts show the instant silhouette then crossfade to the shared
/// `FeedRouteSnapshots` render (cached, throttled — never a live map engine per cell; that's the
/// mistake the card feed already made and fixed).
struct FeedTileMedia: View {
    let item: FeedItem
    var onInkContext: ((InkContext) -> Void)? = nil
    /// Mapped ONCE at view creation. `item.routeCoordinates` walks every point per call, and the
    /// tile's body re-evaluates far more often than the view is rebuilt — a `sample` under load
    /// showed the whole main thread burning in exactly that getter (2026-07-29).
    private let coords: [CLLocationCoordinate2D]?

    init(item: FeedItem, onInkContext: ((InkContext) -> Void)? = nil) {
        self.item = item
        self.onInkContext = onInkContext
        self.coords = item.routeCoordinates
    }

    enum InkContext { case fixedLight, appearance, photo }

    @Environment(\.colorScheme) private var colorScheme
    @State private var photo: UIImage?
    @State private var snapshot: UIImage?

    var body: some View {
        Group {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else if let muscles = item.muscles, muscles.values.contains(where: { $0 > 0 }) {
                ZStack {
                    IridescentWash()
                    MuscleMapView(activation: muscles, forceStatic: true)
                        .padding(Theme.Space.sm)
                }
            } else if let coords, coords.count > 1 {
                if let snapshot {
                    Image(uiImage: snapshot).resizable().scaledToFill()
                        .transition(.opacity)
                } else {
                    ZStack {
                        // Surface, not background: on the white page a background-canvas tile has
                        // invisible edges and the mosaic dissolves — every cell needs its own pane.
                        Theme.surface
                        RouteSilhouette(coords: coords)
                            .stroke(Theme.route, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .padding(Theme.Space.md)
                    }
                }
            } else if item.photoData != nil {
                Theme.surface   // photo still decoding (one hop)
            } else {
                glyph
            }
        }
        .animation(.easeOut(duration: 0.25), value: snapshot != nil)
        .task(id: "\(item.id)-\(colorScheme == .dark)") {
            // The cover rule (2026-07-29): the activity's own visual leads; a photo covers only
            // when the author chose it — or when the post has no route/muscle visual at all.
            if item.coverIsPhoto, let data = item.photoData {
                photo = await ImageDownsampler.thumbnail(data, maxPixel: 480)
                onInkContext?(.photo)
                return
            }
            if item.muscles?.values.contains(where: { $0 > 0 }) == true {
                onInkContext?(.appearance)
                return
            }
            guard let coords, coords.count > 1 else {
                if let data = item.photoData {
                    photo = await ImageDownsampler.thumbnail(data, maxPixel: 480)
                    onInkContext?(.photo)
                } else {
                    onInkContext?(.appearance)
                }
                return
            }
            onInkContext?(.appearance)   // silhouette canvas until the snapshot lands
            #if DEBUG
            // UI tests keep the instant silhouette — XCUITest realizes every lazy cell at once and
            // a hundred queued Mapbox renders starve the run (same guard as the card feed).
            if ProcessInfo.processInfo.arguments.contains("--ui-test-social") { return }
            #endif
            // Small tile → small render with a proportionally thicker route, exactly the profile
            // grid's rule. The width is part of the snapshot cache key, so tiles and full cards
            // never collide. Failed renders retry with backoff (the card feed's lesson): a cold
            // launch's first burst can rate-limit, and without retries the wall stays silhouettes
            // for the whole session.
            var attempt = 0
            while !Task.isCancelled, attempt < 3 {
                if let rendered = await FeedRouteSnapshots.image(
                    post: item.id, coordinates: coords, style: item.mapStyle, scheme: colorScheme,
                    size: CGSize(width: 300, height: 400), routeWidth: 4.5) {
                    snapshot = rendered
                    onInkContext?(item.mapStyle.bakesDarkCanvas ? .photo : .fixedLight)
                    return
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(min(Double(attempt) * 2, 6)))
            }
        }
    }

    private var glyph: some View {
        ZStack {
            IridescentWash()
            Image(systemName: item.type.systemImage)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.85))
        }
    }
}

/// Dim-only press feedback — at a 2pt gutter a scale-down opens a visible hole in the mosaic
/// (the profile grid learned this; same style, duplicated because its version is file-private).
private struct FeedTilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The wall strip's live indicator: one small run-trace-lavender dot with a slow breathe
/// (opacity only, ~1.6s — nothing close to a strobe). Reduce Motion holds it steady.
struct LiveDot: View {
    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Theme.route)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1 : (bright ? 1 : 0.35))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Scope tabs

/// Friends | Global as quiet TEXT tabs with a sliding underline — the TikTok/For-You grammar, in
/// our type. An earlier pass floated a second glass capsule under the Profile ↔ Community slider;
/// two same-shaped pills stacked on one center axis read as a mistake (owner call, 2026-07-29).
/// Text tabs give the page a real hierarchy instead: capsule = which surface, tabs = whose posts.
/// The strip owns its background + bottom hairline, so the wall tucks under it exactly the way the
/// profile grid tucks under its Grid/Highlights bar — one structural language.
struct CommunityScopeTabs: View {
    @Binding var scopeRaw: String
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Halves, not a centered pair (owner call 2026-07-30): each tab owns its half of the bar —
        // Friends centered in the left half, Global in the right — Instagram's exact geometry.
        // The whole half is the tap target.
        HStack(spacing: 0) {
            ForEach(CommunityScope.allCases, id: \.self) { s in
                tab(s)
            }
        }
        .padding(.top, Theme.Space.md)
        .background(Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func tab(_ s: CommunityScope) -> some View {
        let on = CommunityScope(rawValue: scopeRaw) == s
        return Button {
            guard !on else { return }
            // One fixed weight — an active-bold swap re-measures the labels and the whole row
            // shuffles sideways on every switch. State is carried by ink + the sliding bar.
            if reduceMotion { scopeRaw = s.rawValue }
            else { withAnimation(.easeOut(duration: 0.2)) { scopeRaw = s.rawValue } }
            Haptics.selection()
        } label: {
            VStack(spacing: Theme.Space.sm) {
                Text(s.label)
                    .font(.rounded(15, weight: .semibold))
                ZStack {
                    Color.clear.frame(width: 26, height: 2)
                    if on {
                        // Lavender marks selected (rebrand 2026-08-16).
                        Capsule().fill(Theme.purple)
                            .frame(width: 26, height: 2)
                            .matchedGeometryEffect(id: "communityScopeUnderline", in: underline)
                    }
                }
            }
            .foregroundStyle(on ? Theme.ink : Theme.inkTertiary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// Two-layer legibility shadow for text over photo media — structurally ABSENT when inactive.
/// A `.shadow` with 0-opacity color still allocates its offscreen pass; grids apply this per
/// tile, so the dead passes were real scroll cost (perf audit 2026-08-13). Shared by the
/// community wall and the profile grid so the two walls keep identical text treatment.
struct PhotoLegibilityShadow: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content
                .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
                .shadow(color: .black.opacity(0.25), radius: 5)
        } else {
            content
        }
    }
}
