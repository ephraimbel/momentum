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

        let options = MKMapSnapshotter.Options()
        options.region = region(for: coordinates)
        options.size = size
        options.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)

        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = await start(snapshotter) else { return nil }

        let renderer = UIGraphicsImageRenderer(size: size)
        let routeColor = UIColor(Theme.route)
        return renderer.pngData { _ in
            snapshot.image.draw(at: .zero)
            let path = UIBezierPath()
            for (i, coord) in coordinates.enumerated() {
                let p = snapshot.point(for: coord)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.lineWidth = 6
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            routeColor.setStroke()
            path.stroke()
        }
    }

    private static func start(_ snapshotter: MKMapSnapshotter) async -> MKMapSnapshotter.Snapshot? {
        await withCheckedContinuation { cont in
            snapshotter.start(with: .main) { snapshot, _ in cont.resume(returning: snapshot) }
        }
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
