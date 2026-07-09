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

    var body: some View {
        MapReader { proxy in
            Map(initialViewport: viewport) {
                if let start = coordinates.first, coordinates.count > 1 {
                    MapViewAnnotation(coordinate: start) { startPin }.allowOverlap(true)
                }
                if let finish = coordinates.last, coordinates.count > 1 {
                    MapViewAnnotation(coordinate: finish) { finishPin }.allowOverlap(true)
                }
            }
            .mapStyle(style.mapboxStyle)
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

        let casing = LineLayer(id: "route-casing", source: "route-src")
            .lineColor(StyleColor(UIColor.white))
            .lineWidth(6).lineCap(.round).lineJoin(.round)
        try? map.addLayer(casing)

        var line = LineLayer(id: "route-line", source: "route-src")
            .lineWidth(4).lineCap(.round).lineJoin(.round)
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
    private var viewport: Viewport {
        guard coordinates.count > 1 else {
            if let c = coordinates.first { return .camera(center: c, zoom: 14) }
            return .idle
        }
        return .overview(geometry: LineString(coordinates),
                         geometryPadding: EdgeInsets(top: padding, leading: padding,
                                                     bottom: padding, trailing: padding))
    }
}
