import SwiftUI
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

    var body: some View {
        switch media {
        case .photo(let ui):
            Image(uiImage: ui).resizable().scaledToFill()
        case .muscle(let activation):
            muscleMedia(activation)
        case .snapshot(let ui):
            Image(uiImage: ui).resizable().scaledToFill()
        case .route(let coords):
            routeMedia(coords)
        case .glyph:
            glyphMedia
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

    private var media: Media {
        if let data = workout.heroPhotoData, let ui = UIImage(data: data) { return .photo(ui) }
        if workout.type.isStrengthStyle, let session = workout.strength {
            let activation = MuscleActivation.from(session: session)
            if activation.values.contains(where: { $0 > 0 }) { return .muscle(activation) }
        }
        if workout.type.isGPS {
            let coords = routeCoords
            // Immersive prefers the live, framed Mapbox route over the small pre-rendered PNG.
            if style == .immersive, coords.count > 1 { return .route(coords) }
            if let data = workout.gps?.mapSnapshotData, let ui = UIImage(data: data) { return .snapshot(ui) }
            if coords.count > 1 { return .route(coords) }
        }
        return .glyph
    }

    private var routeCoords: [CLLocationCoordinate2D] {
        workout.gps?.routeCoordinates(type: workout.type) ?? []
    }

    // MARK: Renderers

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
            RouteMapView(coordinates: coords, style: .standard)
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
