import Foundation
import MapKit
import UIKit
import SwiftUI

/// Renders a clean, muted route snapshot (PRD §8.5) — a Strava-style image of the run drawn on a
/// light muted map, stored in `GPSDetail.mapSnapshotData` and shown as the workout's image in
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

        let options = MKMapSnapshotter.Options()
        options.region = region(for: drawn)
        options.size = size
        options.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)

        let snapshotter = MKMapSnapshotter(options: options)
        let routeColor = UIColor(Theme.route)

        // Render the route on the snapshot inside the completion (on the main queue) and resume
        // with the Sendable PNG `Data` — avoids sending the non-Sendable snapshot across actors.
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            snapshotter.start(with: .main) { snapshot, _ in
                guard let snapshot else { cont.resume(returning: nil); return }
                let renderer = UIGraphicsImageRenderer(size: size)
                let data = renderer.pngData { _ in
                    snapshot.image.draw(at: .zero)
                    let path = UIBezierPath()
                    for (i, coord) in drawn.enumerated() {
                        let p = snapshot.point(for: coord)
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.lineWidth = 6
                    path.lineJoinStyle = .round
                    path.lineCapStyle = .round
                    routeColor.setStroke()
                    path.stroke()
                }
                cont.resume(returning: data)
            }
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

    private static func region(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.003, (maxLat - minLat) * 1.4),
                                    longitudeDelta: max(0.003, (maxLon - minLon) * 1.4))
        return MKCoordinateRegion(center: center, span: span)
    }
}
