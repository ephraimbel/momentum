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
}
