import SwiftUI
import MapboxMaps

/// Changing a basemap changes its pitch, not the place the athlete was looking at. Keep following
/// only if already following AND authorized; a style tap must never request location permission.
enum MapStyleCamera {
    static func retilted(_ viewport: Viewport, camera: CameraState, pitch: CGFloat,
                         authorized: Bool) -> Viewport {
        if let follow = viewport.followPuck, authorized {
            return .followPuck(zoom: camera.zoom, bearing: follow.bearing, pitch: pitch)
        }
        return .camera(center: camera.center, zoom: camera.zoom, bearing: camera.bearing, pitch: pitch)
    }
}
