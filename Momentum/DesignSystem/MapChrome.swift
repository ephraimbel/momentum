// `@_spi(Restricted)`: the SDK gates `LogoViewOptions.visibility` and
// `AttributionButtonOptions.visibility` behind this SPI group and offers no other way to hide
// them (neither is an initializer parameter). Everything else in this file is ordinary public API.
@_spi(Restricted) import MapboxMaps

/// Bare map chrome: nothing the SDK draws over the map survives (owner call 2026-09-07). The
/// scale bar and compass were already gone; the logo and the attribution button now go with them,
/// so a route, a heatmap and a live run are the map and nothing else.
///
/// **The credit did not disappear, it moved.** Settings' colophon carries "© Mapbox" and
/// "© OpenStreetMap" as tappable links to each licence, which is where this app's attribution
/// lives and why these ornaments can be hidden here. `RouteSnapshotter` has baked its images
/// without them since 2026-07-10 on the same reasoning; this brings the live maps in line.
/// Keeping the policy in one place is what stops a screen from drifting back on its own.
enum MapChrome {
    static var minimal: OrnamentOptions {
        // The logo and attribution carry their visibility as a settable property rather than an
        // init parameter, so they are built and then hidden.
        var logo = LogoViewOptions()
        logo.visibility = .hidden
        var attribution = AttributionButtonOptions()
        attribution.visibility = .hidden
        return OrnamentOptions(
            scaleBar: ScaleBarViewOptions(visibility: .hidden),
            compass: CompassViewOptions(visibility: .hidden),
            logo: logo,
            attributionButton: attribution
        )
    }

    /// Strip the basemap's points of interest and transit markers on a map whose subject is a
    /// **route**.
    ///
    /// Mapbox's default styles sell a place: museums, hotels, theatres and rail stops, in bright
    /// pinks and purples that no other pixel in this app is allowed to be. On a browsing map that's
    /// the point. On a finished run it is a route line competing with a theatre pin for the frame,
    /// on the one image an athlete screenshots and sends to someone. Street names and neighbourhood
    /// labels stay: those orient you, which is the only job labels have here.
    ///
    /// Both style families are handled because the athlete picks between them. Mapbox Standard
    /// exposes its label groups as import config (the supported switch, which survives style
    /// updates); the classic styles carry theirs as ordinary symbol layers, hidden by id. Every
    /// call is `try?` on purpose: a style that has neither is simply left as it is, and a route map
    /// with labels is a cosmetic miss, not a broken screen.
    @MainActor
    static func hidePointsOfInterest(on map: MapboxMap?) {
        guard let map else { return }
        for config in ["showPointOfInterestLabels", "showTransitLabels"] {
            try? map.setStyleImportConfigProperty(for: "basemap", config: config, value: false)
        }
        for layer in map.allLayerIdentifiers
        where layer.id.hasPrefix("poi") || layer.id.hasPrefix("transit") || layer.id.hasPrefix("airport") {
            try? map.setLayerProperty(for: layer.id, property: "visibility", value: "none")
        }
    }
}
