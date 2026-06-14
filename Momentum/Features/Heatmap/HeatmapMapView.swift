import SwiftUI
import MapKit

/// Hosts an `MKMapView` with a custom heat overlay — SwiftUI's `Map` can't render arbitrary
/// `MKOverlay`s, so we drop to a representable. Base layer switches via `MapStyleOption`; the heat is
/// drawn by `HeatmapOverlayRenderer`. The athlete's own density only (PRD "private mirror").
struct HeatmapMapView: UIViewRepresentable {
    let cells: [HeatCell]
    let style: MapStyleOption
    let region: MKCoordinateRegion?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        if let region { map.setRegion(region, animated: false) }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.preferredConfiguration = Self.configuration(for: style)
        guard context.coordinator.cells != cells else { return }   // only rebuild when data changes
        context.coordinator.cells = cells
        map.removeOverlays(map.overlays)
        if !cells.isEmpty { map.addOverlay(HeatmapOverlay(cells: cells), level: .aboveLabels) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var cells: [HeatCell] = []
        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            (overlay as? HeatmapOverlay).map(HeatmapOverlayRenderer.init) ?? MKOverlayRenderer(overlay: overlay)
        }
    }

    /// `MapStyleOption` → the `MKMapView` equivalent (the SwiftUI `MapStyle` can't be applied to a
    /// raw `MKMapView`). Same three layers, POIs excluded.
    static func configuration(for style: MapStyleOption) -> MKMapConfiguration {
        switch style {
        case .standard:
            let c = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            c.pointOfInterestFilter = .excludingAll
            return c
        case .hybrid:
            let c = MKHybridMapConfiguration(elevationStyle: .realistic)
            c.pointOfInterestFilter = .excludingAll
            return c
        case .satellite:
            return MKImageryMapConfiguration(elevationStyle: .realistic)
        }
    }
}

/// The heat overlay — carries the binned cells and the map rect they span.
final class HeatmapOverlay: NSObject, MKOverlay {
    let cells: [HeatCell]
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(cells: [HeatCell]) {
        self.cells = cells
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for cell in cells {
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: cell.lat, longitude: cell.lon))
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        // Pad so edge blobs aren't clipped (and guard the single-cell case).
        let pad = max(maxX - minX, maxY - minY) * 0.1 + 2000
        let rect = MKMapRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2)
        self.boundingMapRect = rect
        self.coordinate = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        super.init()
    }
}

/// Draws each cell as a soft radial blob with **additive** blending, so overlapping/frequented areas
/// accumulate toward a white-hot core — the iridescent ramp (PRD §6 earned-iridescence) instead of
/// Strava's red. Blobs are sized in metres, so they zoom geographically with the map.
final class HeatmapOverlayRenderer: MKOverlayRenderer {
    private let cells: [HeatCell]
    private let gradient: CGGradient
    private let blobMeters = 70.0

    init(overlay: HeatmapOverlay) {
        self.cells = overlay.cells
        self.gradient = Self.makeGradient()
        super.init(overlay: overlay)
    }

    /// White-hot centre → two iridescent stops → clear. A single blob already carries an oil-slick
    /// falloff; additive accumulation pushes dense cores toward white.
    private static func makeGradient() -> CGGradient {
        let iri = Theme.iridescent
        func ui(_ i: Int) -> UIColor { UIColor(iri[max(0, min(iri.count - 1, i))]) }
        let colors = [
            UIColor.white.withAlphaComponent(0.85).cgColor,
            ui(1).withAlphaComponent(0.65).cgColor,
            ui(3).withAlphaComponent(0.35).cgColor,
            ui(3).withAlphaComponent(0.0).cgColor,
        ] as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0.0, 0.35, 0.7, 1.0])!
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.setBlendMode(.plusLighter)
        for cell in cells {
            let mp = MKMapPoint(CLLocationCoordinate2D(latitude: cell.lat, longitude: cell.lon))
            let r = blobMeters * MKMapPointsPerMeterAtLatitude(cell.lat)
            let blobRect = MKMapRect(x: mp.x - r, y: mp.y - r, width: r * 2, height: r * 2)
            guard mapRect.intersects(blobRect) else { continue }     // skip blobs outside this tile
            let center = point(for: mp)
            // Perceptual curve: a one-off pass still shows, frequented cells brighten fast.
            let alpha = 0.12 + 0.72 * pow(cell.weight, 0.55)
            context.saveGState()
            context.setAlpha(CGFloat(alpha))
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: CGFloat(r), options: [])
            context.restoreGState()
        }
    }
}

#Preview {
    // Synthetic cluster so the canvas shows the renderer without a data store — a dense core with a
    // few radiating arms, like a real "where I run" map.
    let base = (lat: 30.2672, lon: -97.7431)
    var cells: [HeatCell] = []
    for ring in 0..<14 {
        let count = max(1, 14 - ring)                  // denser toward the centre
        for k in 0..<(ring * 6 + 1) {
            let a = Double(k) / Double(ring * 6 + 1) * 2 * .pi
            let d = Double(ring) * 0.0006
            cells.append(HeatCell(lat: base.lat + d * sin(a), lon: base.lon + d * cos(a),
                                  count: count, weight: Double(count) / 14))
        }
    }
    return HeatmapMapView(cells: cells, style: .standard,
                          region: MKCoordinateRegion(center: .init(latitude: base.lat, longitude: base.lon),
                                                     span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04)))
        .ignoresSafeArea()
}
