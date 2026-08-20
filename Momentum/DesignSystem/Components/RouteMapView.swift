import SwiftUI
import CoreLocation
import MapboxMaps

/// Lets the surface that OWNS the overlay chrome (the immersive pager page) talk to the map's
/// camera without RouteMapView knowing anything about that surface's layout: the page renders its
/// own re-center control wherever its design wants it, and the map just reports "the athlete has
/// explored away from the fitted overview" and answers the re-center call.
@Observable
final class RouteMapCameraHandle {
    /// True once a gesture has moved the camera off the fitted whole-route overview.
    fileprivate(set) var isExplored = false
    fileprivate var recenterAction: (() -> Void)?
    /// Animate the camera back to the whole-route overview.
    func recenter() { recenterAction?() }
}

/// A Mapbox map that frames a single completed route — shared by the cardio summary and history
/// detail. The route is drawn as a **periwinkle→lilac gradient** with a white casing (a `LineLayer`,
/// which is safe here because the route is static — a live-updating gradient crashes Mapbox).
/// Non-interactive by default (a display canvas, not an explorable map).
struct RouteMapView: View {
    let coordinates: [CLLocationCoordinate2D]
    /// Defaults to the athlete's persisted app-wide style, read at init (summary/history cards).
    var style: MapStyleOption = .persisted
    var interactive: Bool = false
    var padding: CGFloat = 28
    /// See `RouteMapCameraHandle`; only meaningful when `interactive`.
    var cameraHandle: RouteMapCameraHandle? = nil
    @Environment(\.colorScheme) private var colorScheme
    /// A live viewport BINDING, not `initialViewport`: the initial form is applied exactly once,
    /// at whatever size the map happens to have at creation — inside a lazy container (the
    /// profile's immersive pager) that's a placeholder-sized frame, so the "fit the whole route"
    /// camera was computed for the wrong canvas and stuck zoomed-in (caught on device
    /// 2026-07-24). The `.overview` viewport STATE re-fits whenever the map's real size lands —
    /// the whole route, every time, on every surface.
    @State private var viewport: Viewport
    /// True once the basemap + route layers are in — gates the fade-in (see `.opacity` below).
    @State private var styleReady = false

    init(coordinates: [CLLocationCoordinate2D], style: MapStyleOption = .persisted,
         interactive: Bool = false, padding: CGFloat = 28,
         cameraHandle: RouteMapCameraHandle? = nil) {
        self.coordinates = coordinates
        self.style = style
        self.interactive = interactive
        self.padding = padding
        self.cameraHandle = cameraHandle
        _viewport = State(initialValue: Self.fit(coordinates, padding: padding))
    }

    var body: some View {
        MapReader { proxy in
            Map(viewport: $viewport) {
                // The numbered per-mile/km badges that used to render here were REMOVED entirely
                // (owner call 2026-07-30 — they read as noise, not information). The route keeps
                // exactly two annotations: where it began and where it ended.
                if let start = coordinates.first, coordinates.count > 1 {
                    MapViewAnnotation(coordinate: start) { startPin }.allowOverlap(true)
                }
                if let finish = coordinates.last, coordinates.count > 1 {
                    MapViewAnnotation(coordinate: finish) { finishPin }.allowOverlap(true)
                }
            }
            .mapStyle(style.mapboxStyle(for: colorScheme))
            .ornamentOptions(MapChrome.hidden)
            .gestureOptions(interactive ? Self.exploreGestures : GestureOptions())
            .onStyleLoaded { _ in
                // Before the route goes on: the basemap's POI and transit pins are the only thing
                // that ever competes with it for the frame. See `MapChrome.hidePointsOfInterest`.
                MapChrome.hidePointsOfInterest(on: proxy.map)
                addRouteLayers(proxy.map)
                styleReady = true
            }
            // Held on the quiet surface until the style (and the route layers) are actually in —
            // an empty half-loaded basemap frame is never the first thing a summary shows.
            .opacity(styleReady ? 1 : 0)
            .background(Theme.surface)
            .animation(.easeOut(duration: 0.25), value: styleReady)
            .allowsHitTesting(interactive)
            .onChange(of: viewport.isIdle) { _, idle in
                // A gesture parks the viewport at .idle — that's the "explored" signal.
                cameraHandle?.isExplored = idle
            }
            .onAppear {
                cameraHandle?.recenterAction = { [coordinates, padding] in
                    withViewportAnimation(.easeOut(duration: 0.7)) {
                        viewport = Self.fit(coordinates, padding: padding)
                    }
                }
            }
        }
    }

    /// The immersive pager owns single-finger vertical drags (that's how you swipe between
    /// workouts), so exploring is everything BUT a one-finger pan: pinch to zoom (with pan while
    /// pinching), double-tap / two-finger-tap zoom, and quick-zoom. No rotate/pitch — a route
    /// study, not a flight sim.
    private static var exploreGestures: GestureOptions {
        var options = GestureOptions()
        options.panEnabled = false
        options.pinchEnabled = true
        options.pinchZoomEnabled = true
        options.pinchPanEnabled = true
        options.rotateEnabled = false
        options.pitchEnabled = false
        options.simultaneousRotateAndPinchZoomEnabled = false
        options.doubleTapToZoomInEnabled = true
        options.doubleTouchToZoomOutEnabled = true
        options.quickZoomEnabled = true
        return options
    }

    /// Start and finish use the SHARED marks (`RouteEndpoints`) — the same objects the grid tiles
    /// and snapshots draw. They used to be this file's own 18pt dot and 22pt black flag-disc, which
    /// is why opening a route from the profile showed a visibly different marker than the tile you
    /// tapped (owner report 2026-07-30). One definition, one look, every surface.
    private var startPin: some View { RouteStartMark(diameter: 12) }
    private var finishPin: some View { RouteFinishMark(diameter: 12) }

    /// Adds the casing + gradient route layers once the style is ready (re-added if the style reloads).
    private func addRouteLayers(_ map: MapboxMap?) {
        guard let map, map.isStyleLoaded, coordinates.count > 1, !map.sourceExists(withId: "route-src") else { return }
        var source = GeoJSONSource(id: "route-src")
        source.lineMetrics = true                       // required for the line-progress gradient
        source.data = .geometry(.lineString(LineString(coordinates)))
        try? map.addSource(source)

        // Full emissive strength: Standard-family styles (Realistic/Dusk/Night — and the paired
        // dark looks) light custom layers with the 3D scene's lighting, which dims an unlit line
        // to ~35% at night — the route read near-black instead of the brand purple. Emissive
        // layers self-illuminate; classic flat styles ignore the property.
        let casing = LineLayer(id: "route-casing", source: "route-src")
            .lineColor(StyleColor(UIColor.white))
            .lineWidth(6).lineCap(.round).lineJoin(.round)
            .lineEmissiveStrength(1)
        try? map.addLayer(casing)

        var line = LineLayer(id: "route-line", source: "route-src")
            .lineWidth(4).lineCap(.round).lineJoin(.round)
            .lineEmissiveStrength(1)
        // One solid trace color on every map (owner call 2026-08-19) — the old lavender→lilac
        // gradient end is gone; direction reads from the endpoint dots, not a color shift.
        line.lineGradient = .expression(Exp(.interpolate) {
            Exp(.linear)
            Exp(.lineProgress)
            0.0
            UIColor(Theme.route)
            1.0
            UIColor(Theme.route)
        })
        try? map.addLayer(line)
    }

    /// Frame the whole route with padding; fall back to a centered camera for a single point.
    private static func fit(_ coordinates: [CLLocationCoordinate2D], padding: CGFloat) -> Viewport {
        guard coordinates.count > 1 else {
            if let c = coordinates.first { return .camera(center: c, zoom: 14) }
            return .idle
        }
        // maxZoom: a tiny route (a 100 m test lap, a track repeat) otherwise fits to
        // building-level zoom where the line is a scribble on one rooftop — clamp to street level.
        return .overview(geometry: LineString(coordinates),
                         geometryPadding: EdgeInsets(top: padding, leading: padding,
                                                     bottom: padding, trailing: padding),
                         maxZoom: 17)
    }
}
