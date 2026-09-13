import SwiftUI
import SwiftData
import CoreLocation

/// The visual artifact of a workout — the "post" media for the TikTok-style profile grid and the
/// full-screen immersive pager. Picks the richest available representation, in order: an attached
/// photo → a glowing muscle map (strength) → the pre-rendered route snapshot (GPS) → a drawn route
/// silhouette → the sport glyph. The same selector drives both surfaces so a run always looks like a
/// run and a lift always lights the muscles it worked.
///
/// `.tile` renders compact and **static** (many stack into a `LazyVGrid`, so no animated mesh per
/// cell); `.immersive` renders full-bleed and may animate (live route map, igniting muscle map).
///
/// **Resolved media is remembered for the session** (`WorkoutMediaCache`, 2026-09-12). A lazy grid
/// cell or pager page that comes back into view is a NEW view with empty `@State`; it used to start
/// from a grey pane, decode the same thumbnail again (or walk the same strength sets), and fade the
/// same picture back in — the flash the grid showed on every scroll-back. Now `init` probes the
/// cache synchronously and the first frame already carries the finished media.
struct WorkoutTileMedia: View {
    let workout: Workout
    var style: Style = .tile
    /// Grid tiles follow the athlete's saved cover choice. The immersive pager's alternate
    /// route/body slot opts out: once the photo is already the hero, asking this renderer to
    /// honor `coverIsPhoto` would draw that same photo again instead of the workout visual.
    var respectsPhotoCover: Bool = true
    /// Sets the immersive route map's mile/km milestone badges; tiles ignore it.
    var distanceUnit: DistanceUnit = .auto
    /// Immersive only: this page is the one the pager has SETTLED on, so it owns the single live
    /// Mapbox canvas. Neighbours render the same page with the painted route only, and flipping
    /// this never restarts any work — it is deliberately absent from every task key.
    var isLive: Bool = true
    /// Immersive only: exactly one page from the settled one — worth painting the full-bleed frame
    /// ahead of the swipe. The settled page gets the live canvas instead; pages further out keep
    /// their persisted card until they get close.
    var isNear: Bool = true
    /// Immersive only: the pager's page frame, so the page's render and the pager's prefetch share
    /// one cache key. nil measures the view's own frame (previews, other hosts).
    var pageSize: CGSize? = nil
    /// Immersive only: lets the pager page host the re-center control for the explorable map.
    var mapCameraHandle: RouteMapCameraHandle? = nil
    /// Reports which canvas actually got drawn, so an overlay (the grid tile's metric) can pick an
    /// ink that survives on it. Fires on first resolve and again if the snapshot heal swaps the
    /// media — a caller can't derive this itself, because "has a snapshot" changes underneath it.
    var onInkContext: ((InkContext) -> Void)? = nil

    enum Style: String { case tile, immersive }

    /// What an overlay is sitting on.
    ///
    /// The distinction that matters: a route snapshot is baked into a persisted image, so its
    /// luminance is fixed at render time and does NOT follow the athlete's appearance setting —
    /// `Theme.ink` over one flips to near-white in dark mode and vanishes. Muscle/silhouette/glyph
    /// sit on Theme tokens and do follow the appearance; a photo is genuinely unknown.
    enum InkContext { case fixedLight, appearance, photo }

    private func inkContext(for media: Media) -> InkContext {
        switch media {
        case .photo:                   .photo
        case .snapshot, .liveRoute:
            // Since v5 the card is baked in the run's own style, so "snapshot" no longer implies a
            // pale canvas. A dark or satellite basemap takes the photo treatment (white + halo);
            // the pale ones keep fixed dark ink. Getting this wrong is invisible in light mode and
            // illegible in dark — it was already shipped once that way.
            (workout.gps?.mapStyle.bakesDarkCanvas ?? false) ? .photo : .fixedLight
        case .muscle, .route, .glyph:  .appearance
        }
    }

    @Environment(\.modelContext) private var modelContext
    /// Resolved once per tile identity (not per body pass): picking the media re-decodes images,
    /// walks strength sets, and — for a snapshot-less GPS run — Kalman-smooths every GPS sample.
    /// Doing that on every scroll-invalidated `body` was the tile grid's main source of jank.
    @State private var resolved: Media?
    @State private var resolvedWorkoutID: UUID?

    init(workout: Workout, style: Style = .tile, respectsPhotoCover: Bool = true,
         distanceUnit: DistanceUnit = .auto, isLive: Bool = true, isNear: Bool = true,
         pageSize: CGSize? = nil, mapCameraHandle: RouteMapCameraHandle? = nil,
         onInkContext: ((InkContext) -> Void)? = nil) {
        self.workout = workout
        self.style = style
        self.respectsPhotoCover = respectsPhotoCover
        self.distanceUnit = distanceUnit
        self.isLive = isLive
        self.isNear = isNear
        self.pageSize = pageSize
        self.mapCameraHandle = mapCameraHandle
        self.onInkContext = onInkContext
        // Frame one: whatever this exact (workout, revision, surface) resolved to earlier in the
        // session, else whatever can be decided without leaving the main thread (a card that is
        // already decoded, a route page whose card exists). `onInkContext` is reported from the
        // task, never from here — a parent's state can't be written while it is building its
        // children.
        let key = Self.cacheKey(workout: workout, revision: Self.revision(of: workout),
                                style: style, respectsPhotoCover: respectsPhotoCover)
        if let hit = WorkoutMediaCache.cached(key)
            ?? Self.instantMedia(workout: workout, style: style, respectsPhotoCover: respectsPhotoCover) {
            _resolved = State(initialValue: hit)
            _resolvedWorkoutID = State(initialValue: workout.id)
        }
    }

    /// The media `computeMedia()` WOULD pick, when that answer is already in hand: the same
    /// branch order, but every step that needs a decode or a relationship walk returns nil instead
    /// of doing it. Lets a page opened from the grid (whose card the grid just decoded) and a route
    /// page with a persisted card skip the one grey frame between creation and its first task.
    private static func instantMedia(workout: Workout, style: Style, respectsPhotoCover: Bool) -> Media? {
        if respectsPhotoCover, workout.coverIsPhoto {
            guard let data = workout.heroPhotoData,
                  let ui = ImageDownsampler.cached(data, maxPixel: style == .tile ? 480 : 1400) else { return nil }
            return .photo(ui)
        }
        if workout.type.isStrengthStyle, workout.strength != nil { return nil }   // needs the set walk
        if workout.type.isGPS, let gps = workout.gps {
            if style == .immersive {
                return (gps.mapSnapshotData != nil || RouteCoordinateCache.cached(workout.id) != nil)
                    ? .liveRoute : nil
            }
            if let data = gps.mapSnapshotData, let ui = ImageDownsampler.cached(data, maxPixel: 480) {
                return .snapshot(ui)
            }
        }
        return nil
    }

    /// Everything `computeMedia()` branches on. Read in `body` (not once at init) so a change the
    /// parent never re-evaluates for — "Photo as cover" flipping on this very workout — still moves
    /// the task key below (owner report 2026-08-29: the toggle saved and nothing on screen moved).
    private var mediaRevision: Int { Self.revision(of: workout) }

    private static func revision(of workout: Workout) -> Int {
        var h = Hasher()
        h.combine(workout.type)
        h.combine(workout.coverIsPhoto)
        h.combine(MediaFingerprint.value(workout.heroPhotoData))
        h.combine(MediaFingerprint.value(workout.gps?.mapSnapshotData))
        h.combine(workout.gps?.mapSnapshotVersion)
        h.combine(workout.gps?.mapStyleRaw)
        h.combine(workout.strength?.totalSets)
        h.combine(workout.strength?.totalVolumeKg)
        return h.finalize()
    }

    private static func cacheKey(workout: Workout, revision: Int, style: Style, respectsPhotoCover: Bool) -> String {
        "\(workout.id.uuidString)|\(revision)|\(style.rawValue)|\(respectsPhotoCover)"
    }

    var body: some View {
        Group {
            switch resolved {
            case .photo(let ui):
                // Immersive shows the WHOLE image over a blurred fill (the pager rule); tiles
                // keep the straight fill crop.
                if style == .immersive {
                    ZStack {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .blur(radius: 40, opaque: true)
                            .overlay(Color.black.opacity(0.10))
                        Image(uiImage: ui).resizable().scaledToFit()
                    }
                } else {
                    Image(uiImage: ui).resizable().scaledToFill()
                }
            case .muscle(let activation):
                muscleMedia(activation)
            case .snapshot(let ui):
                snapshotMedia(ui)
            case .route(let coords):
                routeMedia(coords)
            case .liveRoute:
                liveRouteMedia
            case .glyph:
                glyphMedia
            case nil:
                Theme.surface   // brief placeholder until the media resolves (one hop)
            }
        }
        // Resolve the media once, then self-heal: a GPS workout whose snapshot render failed at
        // finish shows the silhouette, renders + persists the real map here, then re-resolves so the
        // snapshot swaps in. Keyed on identity so a reused lazy cell recomputes for its new workout.
        //
        // `coverIsPhoto` is IN the key, and has to be: the id alone never changes when the athlete
        // flips "Photo as cover", so the task never re-ran and the tile kept whatever it resolved
        // first — the toggle saved, and nothing on screen moved (owner report 2026-08-29). Anything
        // `computeMedia()` branches on belongs in this key. `isLive`/`isNear` deliberately do NOT:
        // a page becoming the live one must never re-resolve.
        .task(id: "\(workout.id)-\(mediaRevision)-\(respectsPhotoCover)-\(style.rawValue)") {
            // Keep the current image during a same-workout refresh (cover change / snapshot heal).
            // Clearing it first flashed a blank tile on every refresh. A reused cell must still
            // clear the OTHER workout's image, and cancelled tasks must never publish stale media.
            if resolvedWorkoutID != workout.id {
                resolved = nil
                resolvedWorkoutID = workout.id
            }
            let key = Self.cacheKey(workout: workout, revision: mediaRevision,
                                    style: style, respectsPhotoCover: respectsPhotoCover)
            let media: Media
            if let hit = WorkoutMediaCache.cached(key) {
                media = hit
            } else {
                media = await computeMedia()
                guard !Task.isCancelled else { return }
                WorkoutMediaCache.store(media, key: key)
            }
            resolved = media
            onInkContext?(inkContext(for: media))
            let hadSnapshot = workout.gps?.mapSnapshotData != nil
            await WorkoutSnapshotHealer.healIfNeeded(workout, context: modelContext)
            guard !Task.isCancelled else { return }
            // If the heal just produced a snapshot, swap it in for the silhouette fallback — and
            // re-report, because that swap takes the canvas from Theme-backed to fixed light.
            if !hadSnapshot, workout.gps?.mapSnapshotData != nil {
                let healed = await computeMedia()
                guard !Task.isCancelled else { return }
                WorkoutMediaCache.store(healed, key: Self.cacheKey(workout: workout, revision: mediaRevision,
                                                                   style: style, respectsPhotoCover: respectsPhotoCover))
                resolved = healed
                onInkContext?(inkContext(for: healed))
            }
        }
    }

    // MARK: Media selection

    enum Media {
        case photo(UIImage)
        case muscle([MuscleGroup: Double])
        /// Tile: the persisted route card, downsampled.
        case snapshot(UIImage)
        /// Tile: the drawn silhouette, for a run with no card yet (the self-heal path).
        case route([CLLocationCoordinate2D])
        /// Immersive: the full-bleed route page — `ImmersiveRouteMedia` owns its layers and caches.
        case liveRoute
        case glyph
    }

    private func computeMedia() async -> Media {
        // The cover rule (owner call 2026-07-29): the activity's OWN visual leads — route map for
        // GPS, muscle map for lifts — and a photo covers only when the athlete flipped "Photo as
        // cover". Photos still outrank the generic glyph (they never beat the sport's real media).
        if respectsPhotoCover, workout.coverIsPhoto, let ui = await decodedPhoto() { return .photo(ui) }
        if workout.type.isStrengthStyle, let session = workout.strength {
            let activation = MuscleActivation.from(session: session)
            if activation.values.contains(where: { $0 > 0 }) { return .muscle(activation) }
        }
        if workout.type.isGPS, let gps = workout.gps {
            if style == .immersive {
                // A persisted card proves a route exists — hand the page over at once (its first
                // frame IS that card); the route walk happens inside, off the main actor, cached
                // for the session. Only a card-less run has to prove it has samples first.
                if gps.mapSnapshotData != nil || RouteCoordinateCache.cached(workout.id) != nil {
                    return .liveRoute
                }
                let coords = await RouteCoordinateCache.coordinates(for: workout)
                if coords.count > 1 { return .liveRoute }
            } else {
                // Prefer the cached snapshot PNG — only fall back to Kalman-smoothing all samples
                // when there's no snapshot (the self-heal path), never wastefully before the check.
                if let data = gps.mapSnapshotData,
                   let ui = await ImageDownsampler.thumbnail(data, maxPixel: 480) {
                    return .snapshot(ui)
                }
                let coords = await routeCoordsOffMain()
                if coords.count > 1 { return .route(coords) }
            }
        }
        if let ui = await decodedPhoto() { return .photo(ui) }
        return .glyph
    }

    /// Both surfaces decode off-main through the house downsampler (cached, bounded). The
    /// full-bleed page decodes at the media pager's own 1400px — `UIImage(data:)` handed a
    /// full-resolution JPEG to the render server to decode on the very swipe that landed on it.
    private func decodedPhoto() async -> UIImage? {
        guard let data = workout.heroPhotoData else { return nil }
        switch style {
        case .tile:      return await ImageDownsampler.thumbnail(data, maxPixel: 480)
        case .immersive: return await ImageDownsampler.thumbnail(data, maxPixel: 1400)
        }
    }

    /// The route walk faults every GPS sample and Kalman-smooths it — done on the MainActor it
    /// hitched the immersive pager mid-swipe as each page's `.task` fired. Fault + smooth on a
    /// fresh background context instead (the HeatmapSource pattern: only the container and the
    /// detail's persistent id cross the hop — SwiftData models aren't Sendable), handing back
    /// plain coordinates. Transient/preview objects (no container) fall back inline.
    private func routeCoordsOffMain() async -> [CLLocationCoordinate2D] {
        guard let gps = workout.gps else { return [] }
        guard let container = gps.modelContext?.container else {
            return gps.routeCoordinates(type: workout.type)
        }
        let id = gps.persistentModelID
        let type = workout.type
        return await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            guard let detail = context.model(for: id) as? GPSDetail else { return [] }
            return detail.routeCoordinates(type: type)
        }.value
    }

    // MARK: Renderers

    /// The saved route snapshot. New snapshots render PORTRAIT at the tile's own 3:4
    /// (`RouteSnapshotter.workoutTileSize`) with the route inset to the center square — sharp,
    /// full-bleed, whole route visible. Legacy landscape snapshots (pre-portrait) keep the
    /// fit-over-blur letterbox until the healer re-renders them; a straight fill would crop the
    /// route to a meaningless sliver.
    @ViewBuilder
    private func snapshotMedia(_ ui: UIImage) -> some View {
        if style == .immersive || ui.size.height >= ui.size.width {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            ZStack {
                Image(uiImage: ui).resizable().scaledToFill()
                    .blur(radius: 14, opaque: true)
                    .overlay(Theme.background.opacity(0.25))
                Image(uiImage: ui).resizable().scaledToFit()
            }
        }
    }

    @ViewBuilder
    private func muscleMedia(_ activation: [MuscleGroup: Double]) -> some View {
        ZStack {
            IridescentWash()
            if style == .immersive {
                // The ignite plays for the page the athlete ARRIVES on (`.id` remounts the glow
                // as the page goes live); a neighbour holds the finished, fully-lit figure so
                // the swipe never reveals a dark body mid-ignite.
                AnatomyGlowView(activation: activation, sequential: isLive)
                    .id(isLive)
                    .padding(Theme.Space.xl)
            } else {
                MuscleMapView(activation: activation, forceStatic: true)
                    .padding(Theme.Space.sm)
            }
        }
    }

    @ViewBuilder
    private func routeMedia(_ coords: [CLLocationCoordinate2D]) -> some View {
        ZStack {
            Theme.background
            RouteSilhouette(coords: coords)
                .stroke(Theme.route, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .padding(Theme.Space.md)
        }
    }

    @ViewBuilder
    private var liveRouteMedia: some View {
        if let pageSize {
            ImmersiveRouteMedia(workout: workout, isLive: isLive, isNear: isNear,
                                mapCameraHandle: mapCameraHandle, pageSize: pageSize)
        } else {
            GeometryReader { geo in
                ImmersiveRouteMedia(workout: workout, isLive: isLive, isNear: isNear,
                                    mapCameraHandle: mapCameraHandle, pageSize: geo.size)
            }
        }
    }

    private var glyphMedia: some View {
        ZStack {
            IridescentWash()
            Image(systemName: workout.type.systemImage)
                .font(.system(size: style == .immersive ? 96 : 40, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.85))
        }
    }
}

// MARK: - Session cache

/// Resolved workout media, remembered for the session — a bounded LRU keyed on the exact
/// (workout, media revision, surface) a view asked for.
///
/// An explicit LRU rather than `NSCache`, for the reason `FeedRouteSnapshots` gives: its limits are
/// advisory, so nothing can be pinned by a test, and under pressure it may drop everything
/// including what is on screen. Images are costed by their DECODED bitmap; the small cases
/// (activation dictionaries, silhouette points, the glyph/live-route markers) count as entries only.
@MainActor
enum WorkoutMediaCache {
    private static var cache: [String: WorkoutTileMedia.Media] = [:]
    private static var used: [String: Int] = [:]
    private static var tick = 0
    private static var bytes = 0
    /// ~50 grid tiles at 480px (1.2 MB each) plus a handful of full-bleed photos — several
    /// screenfuls in both directions, which is as far back as a scroll ever snaps.
    static let byteBudget = 64 * 1_048_576
    static let entryBudget = 240

    /// The media for this exact key, if it is already in hand — no `await`, no suspension.
    static func cached(_ key: String) -> WorkoutTileMedia.Media? { touch(key) }

    static func store(_ media: WorkoutTileMedia.Media, key: String) {
        observeMemoryWarningsIfNeeded()
        if let old = cache[key] { bytes -= cost(of: old) }
        cache[key] = media
        tick &+= 1
        used[key] = tick
        bytes += cost(of: media)
        while (bytes > byteBudget || cache.count > entryBudget), cache.count > 1 {
            guard let stalest = used.min(by: { $0.value < $1.value })?.key else { break }
            used[stalest] = nil
            if let gone = cache.removeValue(forKey: stalest) { bytes -= cost(of: gone) }
        }
    }

    private static func touch(_ key: String) -> WorkoutTileMedia.Media? {
        guard let hit = cache[key] else { return nil }
        tick &+= 1
        used[key] = tick
        return hit
    }

    private static func cost(of media: WorkoutTileMedia.Media) -> Int {
        switch media {
        case .photo(let ui), .snapshot(let ui):
            Int(ui.size.width * ui.scale * ui.size.height * ui.scale * 4)
        case .route(let coords):
            coords.count * MemoryLayout<CLLocationCoordinate2D>.stride
        case .muscle, .liveRoute, .glyph:
            0
        }
    }

    private static var observingMemory = false
    private static func observeMemoryWarningsIfNeeded() {
        guard !observingMemory else { return }
        observingMemory = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { purge() }
            }
    }

    /// A real memory warning: drop everything. Views on screen keep their own `@State` copy and
    /// re-store on their next resolve.
    static func purge() {
        cache.removeAll()
        used.removeAll()
        bytes = 0
    }

    static var residentCount: Int { cache.count }
    static var residentBytes: Int { bytes }

    #if DEBUG
    static func resetForTesting() { purge() }
    #endif
}
