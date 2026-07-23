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
struct WorkoutTileMedia: View {
    let workout: Workout
    var style: Style = .tile

    enum Style { case tile, immersive }

    @Environment(\.modelContext) private var modelContext
    /// Resolved once per tile identity (not per body pass): picking the media re-decodes images,
    /// walks strength sets, and — for a snapshot-less GPS run — Kalman-smooths every GPS sample.
    /// Doing that on every scroll-invalidated `body` was the tile grid's main source of jank.
    @State private var resolved: Media?

    var body: some View {
        Group {
            switch resolved {
            case .photo(let ui):
                Image(uiImage: ui).resizable().scaledToFill()
            case .muscle(let activation):
                muscleMedia(activation)
            case .snapshot(let ui):
                snapshotMedia(ui)
            case .route(let coords):
                routeMedia(coords)
            case .glyph:
                glyphMedia
            case nil:
                Theme.surface   // brief placeholder until the media resolves (one hop)
            }
        }
        // Resolve the media once, then self-heal: a GPS workout whose snapshot render failed at
        // finish shows the silhouette, renders + persists the real map here, then re-resolves so the
        // snapshot swaps in. Keyed on identity so a reused lazy cell recomputes for its new workout.
        .task(id: workout.id) {
            resolved = await computeMedia()
            let hadSnapshot = workout.gps?.mapSnapshotData != nil
            await WorkoutSnapshotHealer.healIfNeeded(workout, context: modelContext)
            // If the heal just produced a snapshot, swap it in for the silhouette fallback.
            if !hadSnapshot, workout.gps?.mapSnapshotData != nil { resolved = await computeMedia() }
        }
    }

    // MARK: Media selection

    private enum Media {
        case photo(UIImage)
        case muscle([MuscleGroup: Double])
        case snapshot(UIImage)
        case route([CLLocationCoordinate2D])
        case glyph
    }

    private func computeMedia() async -> Media {
        if let data = workout.heroPhotoData {
            // Tiles are ~120pt cells — decode a downsampled thumbnail off-main instead of the
            // full photo bitmap; the full-bleed immersive page keeps full resolution.
            let ui = style == .tile ? await ImageDownsampler.thumbnail(data, maxPixel: 480) : UIImage(data: data)
            if let ui { return .photo(ui) }
        }
        if workout.type.isStrengthStyle, let session = workout.strength {
            let activation = MuscleActivation.from(session: session)
            if activation.values.contains(where: { $0 > 0 }) { return .muscle(activation) }
        }
        if workout.type.isGPS {
            // Immersive prefers the live, framed Mapbox route over the small pre-rendered PNG.
            // Splined like the summary map (RouteSmoothing at its call site) — full-bleed is
            // where angular segments read worst.
            if style == .immersive {
                let coords = await routeCoordsOffMain(smoothed: true)
                if coords.count > 1 { return .route(coords) }
            }
            // Prefer the cached snapshot PNG — only fall back to Kalman-smoothing all samples when
            // there's no snapshot (the self-heal path), never wastefully before the snapshot check.
            if let data = workout.gps?.mapSnapshotData {
                let ui = style == .tile ? await ImageDownsampler.thumbnail(data, maxPixel: 480) : UIImage(data: data)
                if let ui { return .snapshot(ui) }
            }
            let coords = await routeCoordsOffMain()
            if coords.count > 1 { return .route(coords) }
        }
        return .glyph
    }

    /// The route walk faults every GPS sample and Kalman-smooths it — done on the MainActor it
    /// hitched the immersive pager mid-swipe as each page's `.task` fired. Fault + smooth on a
    /// fresh background context instead (the HeatmapSource pattern: only the container and the
    /// detail's persistent id cross the hop — SwiftData models aren't Sendable), handing back
    /// plain coordinates. Transient/preview objects (no container) fall back inline.
    private func routeCoordsOffMain(smoothed: Bool = false) async -> [CLLocationCoordinate2D] {
        guard let gps = workout.gps else { return [] }
        guard let container = gps.modelContext?.container else {
            let raw = gps.routeCoordinates(type: workout.type)
            return smoothed ? RouteSmoothing.smooth(raw) : raw
        }
        let id = gps.persistentModelID
        let type = workout.type
        return await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            guard let detail = context.model(for: id) as? GPSDetail else { return [] }
            let raw = detail.routeCoordinates(type: type)
            return smoothed ? RouteSmoothing.smooth(raw) : raw
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
            Theme.surface
            if style == .immersive {
                AnatomyGlowView(activation: activation, sequential: true)
                    .padding(Theme.Space.xl)
            } else {
                MuscleMapView(activation: activation, forceStatic: true)
                    .padding(Theme.Space.sm)
            }
        }
    }

    @ViewBuilder
    private func routeMedia(_ coords: [CLLocationCoordinate2D]) -> some View {
        if style == .immersive {
            RouteMapView(coordinates: coords, style: workout.gps?.mapStyle ?? .persisted)
        } else {
            ZStack {
                Theme.background
                RouteSilhouette(coords: coords)
                    .stroke(Theme.route, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .padding(Theme.Space.md)
            }
        }
    }

    private var glyphMedia: some View {
        ZStack {
            LinearGradient(colors: Theme.iridescent.map { $0.opacity(0.25) },
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: workout.type.systemImage)
                .font(.system(size: style == .immersive ? 96 : 40, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.85))
        }
    }
}
