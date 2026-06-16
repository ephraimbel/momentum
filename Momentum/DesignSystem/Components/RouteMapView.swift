import SwiftUI
import CoreLocation
import MapboxMaps

/// A Mapbox map that frames a single route polyline — shared by the cardio summary, route suggestion,
/// and history detail. Renders the brand route accent over the chosen base style; non-interactive by
/// default (a display canvas, not an explorable map).
struct RouteMapView: View {
    let coordinates: [CLLocationCoordinate2D]
    var style: MapStyleOption = .standard
    var lineColor: Color = Theme.route
    var interactive: Bool = false
    var padding: CGFloat = 28

    var body: some View {
        Map(initialViewport: viewport) {
            PolylineAnnotation(lineCoordinates: coordinates)
                .lineColor(StyleColor(UIColor(lineColor)))
                .lineWidth(4)
                .lineJoin(.round)
                .lineBorderColor(UIColor.white)      // crisp white casing — pops on any base style
                .lineBorderWidth(1.2)
        }
        .mapStyle(style.mapboxStyle)
        .ornamentOptions(MapChrome.hidden)
        .allowsHitTesting(interactive)
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
