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
    /// Grid tiles follow the athlete's saved cover choice. The immersive pager's alternate
    /// route/body slot opts out: once the photo is already the hero, asking this renderer to
    /// honor `coverIsPhoto` would draw that same photo again instead of the workout visual.
    var respectsPhotoCover: Bool = true
    /// Sets the immersive route map's mile/km milestone badges; tiles ignore it.
    var distanceUnit: DistanceUnit = .auto
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
        case .snapshot:
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

    private var mediaRevision: Int {
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
        // `computeMedia()` branches on belongs in this key.
        .task(id: "\(workout.id)-\(mediaRevision)-\(respectsPhotoCover)-\(style.rawValue)") {
            resolved = nil
            let media = await computeMedia()
            resolved = media
            onInkContext?(inkContext(for: media))
            let hadSnapshot = workout.gps?.mapSnapshotData != nil
            await WorkoutSnapshotHealer.healIfNeeded(workout, context: modelContext)
            // If the heal just produced a snapshot, swap it in for the silhouette fallback — and
            // re-report, because that swap takes the canvas from Theme-backed to fixed light.
            if !hadSnapshot, workout.gps?.mapSnapshotData != nil {
                let healed = await computeMedia()
                resolved = healed
                onInkContext?(inkContext(for: healed))
            }
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
        // The cover rule (owner call 2026-07-29): the activity's OWN visual leads — route map for
        // GPS, muscle map for lifts — and a photo covers only when the athlete flipped "Photo as
        // cover". Photos still outrank the generic glyph (they never beat the sport's real media).
        if respectsPhotoCover, workout.coverIsPhoto, let ui = await decodedPhoto() { return .photo(ui) }
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
        if let ui = await decodedPhoto() { return .photo(ui) }
        return .glyph
    }

    /// Tiles decode a downsampled thumbnail off-main; the full-bleed immersive page keeps full
    /// resolution.
    private func decodedPhoto() async -> UIImage? {
        guard let data = workout.heroPhotoData else { return nil }
        switch style {
        case .tile:      return await ImageDownsampler.thumbnail(data, maxPixel: 480)
        case .immersive: return UIImage(data: data)
        }
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
            IridescentWash()
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
        switch style {
        case .immersive:
            RouteMapView(coordinates: coords, style: workout.gps?.mapStyle ?? .persisted,
                         interactive: true,
                         cameraHandle: mapCameraHandle)
        case .tile:
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
            IridescentWash()
            Image(systemName: workout.type.systemImage)
                .font(.system(size: style == .immersive ? 96 : 40, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.85))
        }
    }
}
