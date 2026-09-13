import SwiftUI
import SwiftData
import CoreLocation
import UIKit

/// The full-bleed route page for one of the athlete's OWN workouts — the community pager's
/// `CommunityPageMedia` contract, applied to a SwiftData run (2026-09-12, the pager smoothness pass).
///
/// **Meaningful pixels on frame one, every time.** Three layers, each a strict upgrade of the one
/// below, and every one of them read SYNCHRONOUSLY from a cache the moment the page is created:
///
/// 1. the run's persisted route card (`gps.mapSnapshotData`, decoded once per session) — the same
///    artwork the grid tile the athlete just tapped is drawn from, so the zoom reads as one object;
/// 2. a full-bleed render of the route at this page's exact size (`FeedRouteSnapshots`, the shared
///    LRU), which the pager prefetches for the pages either side of the one being read;
/// 3. the live, explorable Mapbox canvas — mounted ONLY on the page the pager has settled on, with a
///    transparent loader, so it fades in OVER the painted route instead of replacing it with grey.
///
/// Before this the page was `Theme.surface` grey until every GPS sample had been faulted and
/// Kalman-smoothed, then a live map appeared with an opaque grey loader until its style landed —
/// a blank beat of half a second to two seconds on EVERY swipe, and a 480px grid thumbnail blown up
/// to full screen on the pages either side (owner report 2026-09-12: "glitchy, takes too long to
/// load"). Neighbours never recompute anything on activation: `isLive` is not part of any task key.
struct ImmersiveRouteMedia: View {
    let workout: Workout
    /// This page is the one the pager has settled on — it owns the single live Mapbox view.
    var isLive: Bool
    /// Exactly one page from the settled one: worth rendering the full-bleed frame ahead of the
    /// swipe (the settled page gets the live canvas instead).
    var isNear: Bool = true
    var mapCameraHandle: RouteMapCameraHandle? = nil
    /// The page's frame, supplied by the pager so the render this page requests and the render the
    /// pager prefetches for it share one cache key by construction (a GeometryReader on either side
    /// can disagree by a safe-area rounding and turn every prefetch into a miss).
    let pageSize: CGSize

    @Environment(\.colorScheme) private var colorScheme
    /// The decoded persisted card. Seeded from the session cache so a page the athlete swipes back
    /// to (its `@State` gone with the lazy recycle) still draws the map on its first frame.
    @State private var card: UIImage?
    @State private var coords: [CLLocationCoordinate2D]?
    /// The full-bleed render this page requested itself (joins the pager's prefetch when both ask).
    @State private var page: UIImage?

    init(workout: Workout, isLive: Bool, isNear: Bool = true,
         mapCameraHandle: RouteMapCameraHandle? = nil, pageSize: CGSize) {
        self.workout = workout
        self.isLive = isLive
        self.isNear = isNear
        self.mapCameraHandle = mapCameraHandle
        self.pageSize = pageSize
        _card = State(initialValue: WorkoutRouteCard.cached(for: workout))
        _coords = State(initialValue: RouteCoordinateCache.cached(workout.id))
    }

    private var style: MapStyleOption { workout.gps?.mapStyle ?? .persisted }

    var body: some View {
        let full = page ?? FeedRouteSnapshots.cachedImage(
            post: workout.id, style: style, scheme: colorScheme, size: pageSize,
            endpointDiameter: RouteSnapshotter.EndpointMark.fullBleed,
            insets: RouteStandIn.pageInsets, clipEnds: false)
        ZStack {
            Theme.background
            if let full {
                // Rendered at this page's size with the live map's own fit and the whole route:
                // when the canvas fades in over this, nothing moves.
                Image(uiImage: full).resizable().scaledToFill()
                    .frame(width: pageSize.width, height: pageSize.height)
                    .clipped()
                    .transition(.opacity)
            } else if let card {
                // The persisted card is framed for a 3:4 tile (the route inside 90/180pt insets),
                // so filled onto the page it showed the route LARGER than the live map's fit and
                // the map's arrival read as a zoom-out (owner report 2026-09-13). `RouteStandIn`
                // scales and places the card so its route sits exactly where the map will draw
                // it; until the route is known the loop assumption is a close first guess.
                RouteStandIn(image: card,
                             imageSize: RouteSnapshotter.workoutTileSize,
                             imageInsets: RouteSnapshotter.workoutTileInsets,
                             sourceCoordinates: coords.map(RouteSnapshotter.clippedForCard),
                             canvas: pageSize,
                             targetCoordinates: coords)
                    .transition(.opacity)
            } else if let coords, coords.count > 1 {
                RouteSilhouette(coords: coords, maxPoints: 800)
                    .stroke(Theme.route, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .padding(Theme.Space.xxl)
            }
            if isLive, let coords, coords.count > 1 {
                // Fades in over the painted route once the basemap AND both route layers exist;
                // its loader is transparent so it can never put a blank rectangle over the card.
                RouteMapView(coordinates: coords, style: style, interactive: true,
                             cameraHandle: mapCameraHandle, loadingBackground: .clear)
            }
        }
        .animation(.easeOut(duration: 0.25), value: full != nil)
        .animation(.easeOut(duration: 0.25), value: card != nil)
        // `isLive` is deliberately NOT in this key: activation must never restart the work.
        .task(id: "\(workout.id)-\(colorScheme)-\(Int(pageSize.width))x\(Int(pageSize.height))-\(isNear)") {
            // The full-size decode; a grid-thumbnail stand-in from `cached(for:)` is swapped out
            // in place (same framing, sharper) the moment it lands.
            if let full = await WorkoutRouteCard.image(for: workout), full !== card { card = full }
            guard !Task.isCancelled else { return }
            if coords == nil { coords = await RouteCoordinateCache.coordinates(for: workout) }
            guard !Task.isCancelled, !isLive, isNear, page == nil, full == nil,
                  let coords, coords.count > 1 else { return }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-social") { return }
            #endif
            // A neighbour, one swipe away: paint the full-bleed frame so the live map's arrival
            // is a crossfade of like for like. Not urgent — the live page's canvas comes first —
            // and bounded, because an off-screen page must never hold a render slot forever.
            var attempt = 0
            while !Task.isCancelled, attempt < 3 {
                if let rendered = await FeedRouteSnapshots.image(
                    post: workout.id, coordinates: coords, style: style, scheme: colorScheme,
                    size: pageSize, endpointDiameter: RouteSnapshotter.EndpointMark.fullBleed,
                    insets: RouteStandIn.pageInsets, clipEnds: false) {
                    guard !Task.isCancelled else { return }
                    page = rendered
                    return
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(min(Double(attempt) * 2, 6)))
            }
        }
    }
}

// MARK: - Session caches (pure values; SwiftData never crosses a hop)

/// The route a live map draws for a workout, computed ONCE per session. Faulting every
/// `LocationSample` and running the Kalman + spline pass is the single heaviest thing a pager page
/// does; it used to run again every time a page became the active one, and again when the athlete
/// swiped back. Now it runs on a background context the first time anyone asks and every later
/// reader — the page, the pager's prefetch — gets the same array back synchronously.
@MainActor
enum RouteCoordinateCache {
    private static var cache: [UUID: [CLLocationCoordinate2D]] = [:]
    private static var order: [UUID] = []
    private static var inFlight: [UUID: Task<[CLLocationCoordinate2D], Never>] = [:]
    /// A full marathon is ~10k splined points (160 KB); a few dozen of those is nothing.
    static let entryBudget = 48

    /// The already-smoothed route, if it is in hand — no `await`, no suspension.
    static func cached(_ id: UUID) -> [CLLocationCoordinate2D]? { cache[id] }

    /// The smoothed route, computing it off the main actor on the first request. Concurrent
    /// requests for one workout (its page and the pager's prefetch) share a single walk.
    static func coordinates(for workout: Workout) async -> [CLLocationCoordinate2D] {
        let id = workout.id
        if let hit = cache[id] { return hit }
        if let running = inFlight[id] { return await running.value }
        guard let gps = workout.gps else { return [] }
        let type = workout.type
        let task: Task<[CLLocationCoordinate2D], Never>
        if let container = gps.modelContext?.container {
            let modelID = gps.persistentModelID
            task = Task.detached(priority: .userInitiated) {
                let context = ModelContext(container)
                guard let detail = context.model(for: modelID) as? GPSDetail else { return [] }
                return RouteSmoothing.smooth(detail.routeCoordinates(type: type))
            }
        } else {
            // Transient / preview objects (no container) fall back inline.
            let raw = gps.routeCoordinates(type: type)
            task = Task { RouteSmoothing.smooth(raw) }
        }
        inFlight[id] = task
        let result = await task.value
        inFlight[id] = nil
        if result.count > 1 { store(result, for: id) }
        return result
    }

    private static func store(_ coords: [CLLocationCoordinate2D], for id: UUID) {
        if cache[id] == nil { order.append(id) }
        cache[id] = coords
        while order.count > entryBudget, let stalest = order.first {
            order.removeFirst()
            cache[stalest] = nil
        }
    }

    #if DEBUG
    static func resetForTesting() { cache.removeAll(); order.removeAll(); inFlight.removeAll() }
    static var residentCount: Int { cache.count }
    #endif
}

/// The persisted route card, decoded at full resolution once per session so a pager page — the
/// one just opened from the grid, or one swiped back to — can draw it on its very first frame.
/// Keyed on the card's bytes (a re-render by the healer is a new key) through the house decoder's
/// bounded cache, so nothing here can grow without limit.
@MainActor
enum WorkoutRouteCard {
    /// The persisted card is 660×880 pt rendered at 2×; decoding to its native pixel size keeps a
    /// full-bleed phone page sharp without holding anything larger than the PNG already encodes.
    static let maxPixel: CGFloat = 1760

    /// Falls back to the GRID's 480px decode of the same card: on the very first open from the
    /// grid nothing has decoded the full-size card yet, but the tile the athlete just tapped is in
    /// hand — the exact artwork the zoom grows out of, drawn on frame one instead of a blank page,
    /// and replaced by the sharp decode a beat later in the same framing.
    static func cached(for workout: Workout) -> UIImage? {
        guard let data = workout.gps?.mapSnapshotData else { return nil }
        return ImageDownsampler.cached(data, maxPixel: maxPixel)
            ?? ImageDownsampler.cached(data, maxPixel: 480)
    }

    static func image(for workout: Workout) async -> UIImage? {
        guard let data = workout.gps?.mapSnapshotData else { return nil }
        return await ImageDownsampler.thumbnail(data, maxPixel: maxPixel)
    }

    /// Warm a neighbour's card so the swipe lands on a decoded image. A hit is free.
    static func prefetch(for workout: Workout) {
        guard let data = workout.gps?.mapSnapshotData else { return }
        ImageDownsampler.prefetch(data, maxPixel: maxPixel)
    }
}
