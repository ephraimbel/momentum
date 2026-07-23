import SwiftUI
import CoreLocation
import MapboxMaps

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
    @Environment(\.colorScheme) private var colorScheme
    /// A live viewport BINDING, not `initialViewport`: the initial form is applied exactly once,
    /// at whatever size the map happens to have at creation — inside a lazy container (the
    /// profile's immersive pager) that's a placeholder-sized frame, so the "fit the whole route"
    /// camera was computed for the wrong canvas and stuck zoomed-in (caught on device
    /// 2026-07-24). The `.overview` viewport STATE re-fits whenever the map's real size lands —
    /// the whole route, every time, on every surface.
    @State private var viewport: Viewport

    init(coordinates: [CLLocationCoordinate2D], style: MapStyleOption = .persisted,
         interactive: Bool = false, padding: CGFloat = 28) {
        self.coordinates = coordinates
        self.style = style
        self.interactive = interactive
        self.padding = padding
        _viewport = State(initialValue: Self.fit(coordinates, padding: padding))
    }

    var body: some View {
        MapReader { proxy in
            Map(viewport: $viewport) {
                if let start = coordinates.first, coordinates.count > 1 {
                    MapViewAnnotation(coordinate: start) { startPin }.allowOverlap(true)
                }
                if let finish = coordinates.last, coordinates.count > 1 {
                    MapViewAnnotation(coordinate: finish) { finishPin }.allowOverlap(true)
                }
            }
            .mapStyle(style.mapboxStyle(for: colorScheme))
            .ornamentOptions(MapChrome.hidden)
            .onStyleLoaded { _ in addRouteLayers(proxy.map) }
            .allowsHitTesting(interactive)
        }
    }

    /// Green "start" dot (white ring).
    private var startPin: some View {
        ZStack {
            Circle().fill(.white).frame(width: 18, height: 18)
            Circle().fill(Theme.success).frame(width: 11, height: 11)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .accessibilityLabel("Start")
    }

    /// Checkered-flag "finish" marker.
    private var finishPin: some View {
        ZStack {
            Circle().fill(Theme.ink).frame(width: 22, height: 22)
            Image(systemName: "flag.checkered").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.3), radius: 2.5, y: 1)
        .accessibilityLabel("Finish")
    }

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
        line.lineGradient = .expression(Exp(.interpolate) {
            Exp(.linear)
            Exp(.lineProgress)
            0.0
            UIColor(Theme.route)
            1.0
            UIColor(Theme.iridescent[3])
        })
        try? map.addLayer(line)
    }

    /// Frame the whole route with padding; fall back to a centered camera for a single point.
    private static func fit(_ coordinates: [CLLocationCoordinate2D], padding: CGFloat) -> Viewport {
        guard coordinates.count > 1 else {
            if let c = coordinates.first { return .camera(center: c, zoom: 14) }
            return .idle
        }
        return .overview(geometry: LineString(coordinates),
                         geometryPadding: EdgeInsets(top: padding, leading: padding,
                                                     bottom: padding, trailing: padding))
    }
}
