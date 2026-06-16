import Foundation
import CoreLocation
import MapboxMaps
import UIKit
import SwiftUI

/// Renders a clean, muted route snapshot (PRD §8.5) — a Strava-style image of the run drawn on a
/// light muted Mapbox map, stored in `GPSDetail.mapSnapshotData` and shown as the workout's image in
/// Today's "done today" and the History feed.
@MainActor
enum RouteSnapshotter {
    static func snapshot(coordinates: [CLLocationCoordinate2D],
                         size: CGSize = CGSize(width: 640, height: 360)) async -> Data? {
        guard coordinates.count > 1 else { return nil }

        // Hide the first/last ~200m so the thumbnail never starts or ends at the athlete's door
        // (Strava's default), then smooth. Frame to the clipped path so the hidden ends aren't
        // re-revealed by the map's centering.
        let drawn = RouteSmoothing.smooth(clippingEnds(coordinates))
        guard drawn.count > 1 else { return nil }

        let snapshotter = Snapshotter(options: MapSnapshotOptions(size: size, pixelRatio: 2))
        snapshotter.styleURI = .light
        snapshotter.setCamera(to: snapshotter.camera(
            for: drawn, padding: UIEdgeInsets(top: 26, left: 26, bottom: 26, right: 26), bearing: 0, pitch: 0))
        let routeColor = UIColor(Theme.route)

        // Wait for the style to load, then snapshot and stroke the route over it in the overlay
        // handler (Core Graphics). Resume with the Sendable PNG `Data`.
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            var tokens: [AnyCancelable] = []
            var done = false
            func finish(_ data: Data?) {
                guard !done else { return }
                done = true
                tokens.removeAll()
                cont.resume(returning: data)
            }
            snapshotter.onStyleLoaded.observeNext { _ in
                snapshotter.start(overlayHandler: { overlay in
                    let ctx = overlay.context
                    ctx.setLineWidth(6); ctx.setLineJoin(.round); ctx.setLineCap(.round)
                    ctx.setStrokeColor(routeColor.cgColor)
                    for (i, coord) in drawn.enumerated() {
                        let p = overlay.pointForCoordinate(coord)
                        if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
                    }
                    ctx.strokePath()
                }, completion: { result in
                    switch result {
                    case .success(let image): finish(image.pngData())
                    case .failure: finish(nil)
                    }
                })
            }.store(in: &tokens)
            // Never hang the caller if the style/tiles fail to load.
            snapshotter.onMapLoadingError.observeNext { _ in finish(nil) }.store(in: &tokens)
        }
    }

    /// Drop the leading and trailing `meters` of the route (measured along the path) so the snapshot
    /// omits the start/end neighborhood. Skipped for short routes, where clipping would leave nothing
    /// meaningful — a sub-~500m route in a thumbnail reveals little anyway.
    private static func clippingEnds(_ coords: [CLLocationCoordinate2D], meters: Double = 200) -> [CLLocationCoordinate2D] {
        guard coords.count > 3 else { return coords }
        var cum = [0.0]; cum.reserveCapacity(coords.count)
        for i in 1..<coords.count {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            cum.append(cum[i - 1] + b.distance(from: a))
        }
        let total = cum.last ?? 0
        guard total > meters * 2.5 else { return coords }   // too short to clip safely
        let lo = meters, hi = total - meters
        let trimmed = zip(coords, cum).filter { $0.1 >= lo && $0.1 <= hi }.map(\.0)
        return trimmed.count >= 2 ? trimmed : coords
    }

}
