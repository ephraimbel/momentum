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

    /// The wall is hosted inside `ProfileScreen`, whose own body re-evaluates for reasons that
    /// have nothing to do with the feed (its header, its profile `@Query`, a slider animation).
    /// Each of those re-created this grid, which re-ran every realized tile's `body` — measured at
    /// 135 tile evaluations in a single second while the athlete was doing nothing at all. The
    /// grid draws exactly one thing, the posts in order, so it is `Equatable` on precisely that
    /// and a re-creation with the same posts costs one comparison instead of a full cascade.
    var body: some View {
        FeedGridBody(items: items, zoomNamespace: zoomNamespace,
                     onTileAppear: onTileAppear, onOpen: onOpen)
            .equatable()
    }
}

private struct FeedGridBody: View, Equatable {
    let items: [FeedItem]
    var zoomNamespace: Namespace.ID?
    var onTileAppear: ((Int) -> Void)?
    var onOpen: (UUID) -> Void

    /// Identity, in order — never the items' contents. A `FeedItem` carries `photosData`, so a
    /// synthesized `==` would memcmp megabytes of JPEG on every comparison; and a post's content
    /// for a given id is fixed at assembly, so the id list is the whole truth about what this grid
    /// will draw. It is also what keeps the captured closures honest: both call sites derive their
    /// paging state from `items` itself, so any state a closure reads has already moved the list.
    static func == (a: Self, b: Self) -> Bool {
        a.zoomNamespace == b.zoomNamespace
            && a.items.count == b.items.count
            && !zip(a.items, b.items).contains { $0.id != $1.id }
    }

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
        #if DEBUG
        let _ = CommunityPerf.tick("grid")
        #endif
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
            #if DEBUG
            CommunityPerf.mark("FIRSTTILE grid onAppear items=\(items.count)")
            #endif
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
        #if DEBUG
        let _ = CommunityPerf.tick("tile")
        #endif
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
        // When it happened is half of what makes the wall read as a place people are using now —
        // and it's the one thing a sighted athlete gets from the byline that VoiceOver had no
        // route to at all from the grid.
        .accessibilityLabel("\(item.authorName), \(item.title), \(item.statLine), \(item.date.formatted(.relative(presentation: .named)))")
        .accessibilityAddTraits(.isButton)
        // The double-tap-to-respect gesture is unreachable with VoiceOver on (a VoiceOver double
        // tap activates the button). The rotor action is the standard equivalent.
        .accessibilityAction(named: reactions.hasReacted(item.id) ? Text("Liked") : Text("Like")) {
            doubleTapRespect()
        }
    }

    /// IG semantics: a double-tap only ever ADDS respect; un-respecting lives in the pager.
    ///
    /// **The burst belongs to the NEW like (2026-08-29).** It used to play on every double-tap,
    /// including on a post the athlete respected yesterday — a full 44pt heart telling them
    /// something just happened when nothing did. The whole app's rule is that a celebration is
    /// earned; a no-op gets the quiet acknowledgement (a light haptic) and no theatre.
    private func doubleTapRespect() {
        let alreadyRespected = reactions.hasReacted(item.id)
        guard !alreadyRespected else { Haptics.light(); return }
        reactions.toggle(item.id)
        Haptics.success()
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
            // Dynamic Type check, 2026-08-29: at the largest accessibility size this scales ~2.5×,
            // and a lifter's "12,115 lb" then ran the full width of a 130pt tile — wrapping to two
            // lines and sliding under the avatar chip in the opposite corner. One line, shrinking
            // as far as it must, and the chip's own 32pt kept clear. The tile keeps its number
            // (owner call) at every text size, and it stays legible.
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .modifier(PhotoLegibilityShadow(active: ink == .photo))
            .padding(.leading, 7).padding(.trailing, 32).padding(.vertical, 6)
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

    /// One render size for every wall/grid tile, so the synchronous cache read below and the async
    /// render underneath it can only ever agree (the key carries the size — a mismatch would mean
    /// "always a miss", i.e. a fresh Mapbox render on every appearance).
    static let tileSize = CGSize(width: 300, height: 400)
    /// A small tile wants a proportionally thicker trace — the profile grid's exact rule.
    static let tileRouteWidth: CGFloat = 4.5

    /// Whether this post draws a route AT ALL — an O(1) count check.
    ///
    /// `item.routeCoordinates` (which walks and re-boxes every point) used to run in `init`, and
    /// `init` runs on every parent body pass, not once per view. The wall's host re-creates the
    /// grid whenever ProfileScreen re-evaluates, so a settling first second mapped ~90-point
    /// polylines a hundred-plus times for tiles whose picture was already on screen. Nothing needs
    /// the points unless we are actually about to draw the silhouette or start a render, so they
    /// are mapped there and nowhere else.
    private var hasRoute: Bool { (item.routeLatLon?.count ?? 0) > 1 }

    init(item: FeedItem, onInkContext: ((InkContext) -> Void)? = nil) {
        self.item = item
        self.onInkContext = onInkContext
        #if DEBUG
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                CommunityPerf.tick("mediaInit")
                if item.routeLatLon != nil { CommunityPerf.tick("mediaInitCoords") }
            }
        }
        #endif
    }

    enum InkContext { case fixedLight, appearance, photo }

    @Environment(\.colorScheme) private var colorScheme
    @State private var photo: UIImage?
    @State private var snapshot: UIImage?

    /// The already-rendered map for this tile, if one exists — `@State` first, then the shared
    /// cache read synchronously. `LazyVGrid` discards a cell's `@State` when it scrolls off, so
    /// without the second half every scroll-back drew a grey silhouette for a frame and crossfaded
    /// the map in behind it, on tiles that had been finished for minutes.
    private var resolvedSnapshot: UIImage? {
        if let snapshot { return snapshot }
        guard hasRoute else { return nil }
        return FeedRouteSnapshots.cachedImage(post: item.id, style: item.mapStyle,
                                              scheme: colorScheme, size: Self.tileSize,
                                              routeWidth: Self.tileRouteWidth)
    }

    var body: some View {
        #if DEBUG
        let _ = CommunityPerf.tick("mediaBody")
        #endif
        let map = resolvedSnapshot
        Group {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else if let muscles = item.muscles, muscles.values.contains(where: { $0 > 0 }) {
                ZStack {
                    IridescentWash()
                    MuscleMapView(activation: muscles, forceStatic: true)
                        .padding(Theme.Space.sm)
                }
            } else if hasRoute {
                if let map {
                    Image(uiImage: map).resizable().scaledToFill()
                        .transition(.opacity)
                } else {
                    ZStack {
                        // Surface, not background: on the white page a background-canvas tile has
                        // invisible edges and the mosaic dissolves — every cell needs its own pane.
                        Theme.surface
                        RouteSilhouette(coords: item.routeCoordinates ?? [])
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
        .animation(.easeOut(duration: 0.25), value: map != nil)
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
            guard hasRoute else {
                if let data = item.photoData {
                    photo = await ImageDownsampler.thumbnail(data, maxPixel: 480)
                    onInkContext?(.photo)
                } else {
                    onInkContext?(.appearance)
                }
                return
            }
            // Already rendered (a scroll-back, or a neighbour that shares the loop): report the
            // canvas and stop — no engine, no retry loop, and `body` has already drawn the map.
            if map != nil {
                onInkContext?(item.mapStyle.uriStyle(for: colorScheme).bakesDarkCanvas ? .photo : .fixedLight)
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
            guard let coords = item.routeCoordinates, coords.count > 1 else { return }
            var attempt = 0
            while !Task.isCancelled, attempt < 3 {
                if let rendered = await FeedRouteSnapshots.image(
                    post: item.id, coordinates: coords, style: item.mapStyle, scheme: colorScheme,
                    size: Self.tileSize, routeWidth: Self.tileRouteWidth) {
                    snapshot = rendered
                    // The canvas the snapshot ACTUALLY baked, not the style the post stored: a
                    // Realistic/Light post pairs to Dark at night (`uriStyle(for:)`, the same
                    // pairing every map in the app makes), and reading the unresolved style left
                    // near-black ink sitting on a dark basemap.
                    onInkContext?(item.mapStyle.uriStyle(for: colorScheme).bakesDarkCanvas ? .photo : .fixedLight)
                    return
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(min(Double(attempt) * 2, 6)))
            }
        }
    }

    /// The mapless post's tile — a sport symbol on the iridescent wash, **dealt per post**
    /// (2026-08-29).
    ///
    /// It used to be one fixed picture: `IridescentWash()` with no parameters under a 40pt symbol
    /// dead centre, so every swim tile in the app was byte-identical to every other swim tile and a
    /// run of them read as wallpaper, or as a rendering bug. `WashVariation` deals this post's own
    /// gradient axis, corner light, lead hue, symbol size, offset and ink weight from its id — the
    /// same design language, never the same rendering twice. Deliberately narrow ranges: the wall
    /// has to look like many people's posts, not like a theme picker.
    ///
    /// Computed here rather than in `init` so a routed or muscle-mapped tile — which never reaches
    /// this branch — pays nothing for it (`init` runs on every parent body pass; see `hasRoute`).
    private var glyph: some View {
        let deal = WashVariation(seed: item.id)
        let size = Self.glyphSize * deal.glyphScale
        return ZStack {
            IridescentWash(variation: deal)
            Image(systemName: item.type.systemImage)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(deal.glyphInk))
                .offset(x: size * deal.glyphOffsetX, y: size * deal.glyphOffsetY)
        }
    }

    /// The un-varied symbol size — the centre of the range `WashVariation.glyphScale` deals around.
    static let glyphSize: Double = 40
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
        // `.plain` gave these no press state at all: the finger went down on "Global" and nothing
        // acknowledged it until the underline finished sliding. The tile's dim-on-press is the
        // wall's own answer-on-touch-down feedback, so the tabs above it use the same one.
        .buttonStyle(FeedTilePressStyle())
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

#if DEBUG
// MARK: - TEMPORARY perf meter (2026-08-29 responsiveness pass) — remove before landing.

import os

@MainActor
enum CommunityPerf {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--community-perf")
    private static let log = Logger(subsystem: "com.momentum.perf", category: "community")
    private static var counts: [String: Int] = [:]

    static func tick(_ tag: String) {
        guard enabled else { return }
        counts[tag, default: 0] += 1
    }

    static func mark(_ message: String) {
        guard enabled else { return }
        log.notice("\(message, privacy: .public)")
    }

    @discardableResult
    static func time<T>(_ tag: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = body()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        mark(String(format: "TIME %@ %.1fms main=%@", tag, ms, Thread.isMainThread ? "Y" : "N"))
        return r
    }

    static func dump(_ label: String) {
        guard enabled else { return }
        let line = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        mark("EVALS \(label) \(line)")
    }

    static func reset() {
        counts.removeAll()
    }
}
#endif
