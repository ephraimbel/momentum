@_spi(Restricted) import MapboxMaps

/// Hidden map chrome — no scale bar, compass, Mapbox logo, or attribution button — so every map reads
/// as a clean brand canvas. Hiding the Mapbox logo/attribution uses Mapbox's `@_spi(Restricted)` API;
/// the account owner is responsible for the Terms-of-Service implications of removing attribution.
/// Isolated here so this is the only file that touches the restricted SPI.
enum MapChrome {
    static var hidden: OrnamentOptions {
        var logo = LogoViewOptions()
        logo.visibility = .hidden
        var attribution = AttributionButtonOptions()
        attribution.visibility = .hidden
        return OrnamentOptions(
            scaleBar: ScaleBarViewOptions(visibility: .hidden),
            compass: CompassViewOptions(visibility: .hidden),
            logo: logo,
            attributionButton: attribution)
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
