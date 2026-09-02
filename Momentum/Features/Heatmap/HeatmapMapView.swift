import SwiftUI
import CoreLocation
import MapboxMaps
import Turf   // `Feature`/`FeatureCollection` — qualified to avoid the app's paywall `Feature` enum

/// Hosts a Mapbox `MapView` with a native `HeatmapLayer` — the athlete's own density only (PRD
/// "private mirror"). The heat uses the classic thermal ramp (blue → red; user decision 2026-07-09 —
/// data viz speaks the universal heat language, iridescence stays reserved for earned progress) and
/// a zoom-scaled radius so it traces the actual streets they ran. Base layer switches via
/// `MapStyleOption`; the camera opens on the dominant training area.
struct HeatmapMapView: UIViewRepresentable {
    let cells: [HeatCell]
    let style: MapStyleOption

    private static let sourceID = "heat-src"
    private static let layerID = "heat-layer"

    func makeUIView(context: Context) -> MapView {
        let map = MapView(frame: .zero)
        map.gestures.options.rotateEnabled = false
        map.gestures.options.pitchEnabled = false
        map.ornaments.options = MapChrome.minimal
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
        /// The first fit frames the opening shot instantly; later cell changes (a new workout
        /// landing while the card is on screen) EASE there — an un-animated `setCamera` mid-view
        /// was the one raw camera jump left on the app's map surfaces.
        private var hasFitted = false

        func apply(cells: [HeatCell], to map: MapView) {
            self.cells = cells
            guard map.mapboxMap.isStyleLoaded, !cells.isEmpty else { return }
            if fittedCells != cells {
                fittedCells = cells
                // Open on the athlete's primary training area at street level — where the heat
                // actually traces their routes — not a fit of every city they've ever logged.
                let cluster = HeatmapBinning.dominantCluster(cells)
                let coords = (cluster.isEmpty ? cells : cluster)
                    .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let camera = map.mapboxMap.camera(for: coords,
                    padding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), bearing: 0, pitch: 0)
                if hasFitted {
                    map.camera.ease(to: camera, duration: 0.6, curve: .easeInOut, completion: nil)
                } else {
                    hasFitted = true
                    map.mapboxMap.setCamera(to: camera)
                }
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
            // Zoom-scaled radius is what makes the heat TRACE the athlete's actual routes (the cells
            // are a 25 m grid): small when zoomed out (a glowing filament, not a city-sized ball),
            // wide enough at street zoom that adjacent cells fuse into a continuous line.
            layer.heatmapRadius = .expression(
                Exp(.interpolate) {
                    Exp(.exponential) { 1.6 }
                    Exp(.zoom)
                    8; 2
                    11; 4
                    13; 8
                    15; 14
                    17; 24
                }
            )
            layer.heatmapIntensity = .expression(
                Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.zoom)
                    8; 0.8
                    15; 1.3
                }
            )
            layer.heatmapOpacity = .constant(0.85)
            // Classic thermal ramp (user decision 2026-07-09 — heat is data, not earned progress, so
            // it reads in the universal heat language): cold blue → cyan → green → yellow → red-hot.
            layer.heatmapColor = .expression(
                Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.heatmapDensity)
                    0.0; UIColor.clear
                    0.15; UIColor.systemBlue
                    0.4; UIColor.cyan
                    0.6; UIColor.green
                    0.8; UIColor.yellow
                    1.0; UIColor.red
                }
            )
            try? map.mapboxMap.addLayer(layer)
        }
    }
}
