import SwiftUI
import CoreLocation
import MapboxMaps
import Turf   // `Feature`/`FeatureCollection` — qualified to avoid the app's paywall `Feature` enum

/// Hosts a Mapbox `MapView` with a native `HeatmapLayer` — the athlete's own density only (PRD
/// "private mirror"). The heat ramps through the iridescent palette to a white-hot core (PRD §6
/// earned-iridescence) instead of Strava's red. Base layer switches via `MapStyleOption`; the camera
/// fits the cells.
struct HeatmapMapView: UIViewRepresentable {
    let cells: [HeatCell]
    let style: MapStyleOption

    private static let sourceID = "heat-src"
    private static let layerID = "heat-layer"

    func makeUIView(context: Context) -> MapView {
        let map = MapView(frame: .zero)
        map.gestures.options.rotateEnabled = false
        map.gestures.options.pitchEnabled = false
        map.ornaments.options = MapChrome.hidden    // no Mapbox logo/attribution/scale bar/compass
        map.mapboxMap.styleURI = style.styleURI
        // Observe EVERY style load, not just the first: switching the base style tears down all
        // runtime-added sources/layers, so the heat must re-apply each time or it silently vanishes
        // (the "heat areas went away" bug).
        let coordinator = context.coordinator
        coordinator.styleToken = map.mapboxMap.onStyleLoaded.observe { [weak map] _ in
            guard let map else { return }
            coordinator.apply(cells: coordinator.cells, to: map)
        }
        context.coordinator.cells = cells
        return map
    }

    func updateUIView(_ map: MapView, context: Context) {
        if map.mapboxMap.styleURI != style.styleURI { map.mapboxMap.styleURI = style.styleURI }
        if context.coordinator.cells != cells { context.coordinator.apply(cells: cells, to: map) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var cells: [HeatCell] = []
        var styleToken: AnyCancelable?
        /// The cells the camera was last fitted to — a style switch re-applies the heat layers but
        /// must NOT snap the athlete's pan/zoom back to the fitted frame.
        private var fittedCells: [HeatCell] = []

        func apply(cells: [HeatCell], to map: MapView) {
            self.cells = cells
            guard map.mapboxMap.isStyleLoaded, !cells.isEmpty else { return }
            if fittedCells != cells {
                fittedCells = cells
                let coords = cells.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let camera = map.mapboxMap.camera(for: coords,
                    padding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), bearing: 0, pitch: 0)
                map.mapboxMap.setCamera(to: camera)
            }

            let features = cells.map { cell -> Turf.Feature in
                var f = Turf.Feature(geometry: Point(CLLocationCoordinate2D(latitude: cell.lat, longitude: cell.lon)))
                f.properties = ["w": .number(cell.weight)]
                return f
            }
            let collection = FeatureCollection(features: features)
            if map.mapboxMap.sourceExists(withId: HeatmapMapView.sourceID) {
                try? map.mapboxMap.updateGeoJSONSource(withId: HeatmapMapView.sourceID,
                                                       geoJSON: .featureCollection(collection))
                return
            }
            var source = GeoJSONSource(id: HeatmapMapView.sourceID)
            source.data = .featureCollection(collection)
            try? map.mapboxMap.addSource(source)

            var layer = HeatmapLayer(id: HeatmapMapView.layerID, source: HeatmapMapView.sourceID)
            layer.heatmapWeight = .expression(Exp(.get) { "w" })
            layer.heatmapRadius = .constant(30)
            layer.heatmapIntensity = .constant(1.1)
            layer.heatmapOpacity = .constant(0.9)
            // density 0 → clear, ramping through iridescent stops to a white-hot core.
            let iri = Theme.iridescent
            layer.heatmapColor = .expression(
                Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.heatmapDensity)
                    0.0; UIColor.clear
                    0.2; UIColor(iri[3])
                    0.5; UIColor(iri[0])
                    0.8; UIColor(iri[1])
                    1.0; UIColor.white
                }
            )
            try? map.mapboxMap.addLayer(layer)
        }
    }
}
