import CoreLocation
import UIKit
import MapboxMaps
import Testing
@testable import Momentum

struct RouteCameraBoundsTests {
    @MainActor @Test func nativeCameraMatchesTheFullRouteAtBothCanvasSizes() throws {
        let points = (0..<10_000).map { i in
            CLLocationCoordinate2D(latitude: 30 + sin(Double(i) / 100) * 0.1,
                                   longitude: -97 + cos(Double(i) / 100) * 0.2)
        }
        for size in [CGSize(width: 390, height: 240), CGSize(width: 390, height: 844)] {
            let map = MapView(frame: CGRect(origin: .zero, size: size),
                              mapInitOptions: MapInitOptions(styleURI: nil))
            let camera = CameraOptions(bearing: 0, pitch: 0)
            let padding = UIEdgeInsets(top: 32, left: 24, bottom: 72, right: 24)
            let full = try map.mapboxMap.camera(for: points, camera: camera,
                                               coordinatesPadding: padding, maxZoom: 17, offset: nil)
            let bounded = try map.mapboxMap.camera(for: RouteCameraBounds.coordinates(points), camera: camera,
                                                  coordinatesPadding: padding, maxZoom: 17, offset: nil)
            let fullCenter = try #require(full.center), boundedCenter = try #require(bounded.center)
            #expect(abs(fullCenter.latitude - boundedCenter.latitude) < 0.00000001)
            #expect(abs(fullCenter.longitude - boundedCenter.longitude) < 0.00000001)
            #expect(abs(try #require(full.zoom) - #require(bounded.zoom)) < 0.00000001)
        }
    }

    @Test func longRouteRetainsExactExtentsWithBoundedGeometry() {
        let points = (0..<100_000).map { i in
            CLLocationCoordinate2D(latitude: 30 + sin(Double(i)) * 0.1,
                                   longitude: -97 + cos(Double(i)) * 0.1)
        }
        let bounds = RouteCameraBounds.coordinates(points)
        #expect(bounds.count <= 6)
        #expect(bounds.map(\.latitude).min() == points.map(\.latitude).min())
        #expect(bounds.map(\.latitude).max() == points.map(\.latitude).max())
        #expect(bounds.map(\.longitude).min() == points.map(\.longitude).min())
        #expect(bounds.map(\.longitude).max() == points.map(\.longitude).max())
        #expect(bounds.first?.latitude == points.first?.latitude)
        #expect(bounds.last?.longitude == points.last?.longitude)
    }

    @Test func emptyAndInvalidRoutesDoNotCreateAnInvalidCamera() {
        #expect(RouteCameraBounds.coordinates([]).isEmpty)
        #expect(RouteCameraBounds.coordinates([.init(latitude: .nan, longitude: 0), .init(latitude: 91, longitude: 0)]).isEmpty)
        #expect(RouteCameraBounds.coordinates([.init(latitude: 30, longitude: -97)]).count == 1)
    }

    @Test func datelineAndPolarExtremaArePreserved() {
        let points = (0..<20).map { i in
            CLLocationCoordinate2D(latitude: 80 + Double(i) / 100, longitude: i % 2 == 0 ? 179.9 : -179.9)
        }
        let bounds = RouteCameraBounds.coordinates(points)
        #expect(bounds.map(\.longitude).min() == -179.9)
        #expect(bounds.map(\.longitude).max() == 179.9)
        #expect(bounds.map(\.latitude).max() == points.last?.latitude)
    }
}
