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
    /// The canonical size for a WORKOUT's persisted snapshot: portrait 3:4, native to the profile
    /// grid tile (landscape images had to letterbox there, which read as a cut-off route).
    static let workoutTileSize = CGSize(width: 660, height: 880)
    /// Insets for workout snapshots: the route stays inside the CENTER SQUARE, so the 52×52
    /// History thumbnail (a square crop of this portrait image) never clips it.
    static let workoutTileInsets = UIEdgeInsets(top: 130, left: 34, bottom: 130, right: 34)

    static func snapshot(coordinates: [CLLocationCoordinate2D],
                         size: CGSize = CGSize(width: 640, height: 360),
                         styleURI: StyleURI = .light,
                         insets: UIEdgeInsets = UIEdgeInsets(top: 26, left: 26, bottom: 26, right: 26),
                         routeWidth: CGFloat = 6) async -> Data? {
        guard coordinates.count > 1 else { return nil }

        // Hide the first/last ~200m so the thumbnail never starts or ends at the athlete's door
        // (Strava's default). Frame to the clipped path so the hidden ends aren't re-revealed by
        // the map's centering. Smooth only DENSE real-GPS captures (fixes land 2–5m apart — the
        // spline + denoise removes capture wobble): sparse street-following geometry (the community
        // loops from the Directions API carry a vertex per turn) is already EXACT, and smoothing
        // averaged its corners tens of meters into the buildings — the single loudest "fake route"
        // tell. An exact polyline with round joins reads Strava-crisp.
        let clipped = clippingEnds(coordinates)
        let drawn = meanSpanMeters(clipped) < 15 ? RouteSmoothing.smooth(clipped) : clipped
        guard drawn.count > 1 else { return nil }

        // No Mapbox logo/attribution baked into the image — these are in-feed workout cards, not
        // standalone maps (user call 2026-07-10).
        let snapshotter = Snapshotter(options: MapSnapshotOptions(size: size, pixelRatio: 2,
                                                                  showsLogo: false, showsAttribution: false))
        snapshotter.styleURI = styleURI
        snapshotter.setCamera(to: snapshotter.camera(
            for: drawn, padding: insets, bearing: 0, pitch: 0))
        let gradientStart = UIColor(Theme.route), gradientEnd = UIColor(Theme.iridescent[3])

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
            // Casing follows the basemap: a white halo on a DARK map bloomed into a fat glow that
            // swallowed streets (user report 2026-07-15); dark maps get a near-black hairline instead.
            let darkBase = styleURI.rawValue.lowercased().contains("dark")
            let casingColor = darkBase ? UIColor(white: 0.07, alpha: 0.8)
                                       : UIColor.white.withAlphaComponent(0.95)
            snapshotter.onStyleLoaded.observeNext { _ in
                snapshotter.start(overlayHandler: { overlay in
                    let ctx = overlay.context
                    let pts = drawn.map(overlay.pointForCoordinate)
                    guard pts.count > 1 else { return }
                    ctx.setLineJoin(.round); ctx.setLineCap(.round)
                    // Hairline casing under the route so it pops without haloing.
                    ctx.setLineWidth(routeWidth * 1.45); ctx.setStrokeColor(casingColor.cgColor)
                    ctx.beginPath(); ctx.move(to: pts[0]); pts.dropFirst().forEach { ctx.addLine(to: $0) }
                    ctx.strokePath()
                    // Periwinkle→lilac gradient, drawn per segment so the colour follows the path.
                    // `routeWidth` is per-surface: Strava-thin — the route is a precise trace of the
                    // streets, never a marker swipe that covers whole blocks at city zoom.
                    ctx.setLineWidth(routeWidth)
                    for i in 0..<(pts.count - 1) {
                        let frac = Double(i) / Double(pts.count - 1)
                        ctx.setStrokeColor(lerp(gradientStart, gradientEnd, frac).cgColor)
                        ctx.beginPath(); ctx.move(to: pts[i]); ctx.addLine(to: pts[i + 1])
                        ctx.strokePath()
                    }
                }, completion: { result in
                    switch result {
                    case .success(let image): finish(image.pngData())
                    case .failure: finish(nil)
                    }
                })
            }.store(in: &tokens)
            // Only a STYLE failure is fatal (nothing renders without a style). Tile/sprite/glyph
            // errors are partial and transient — the snapshot still completes with what loaded.
            // Failing the whole image on one missed tile left feed cards permanently mapless
            // (user report 2026-07-10).
            snapshotter.onMapLoadingError.observe { error in
                if error.type == .style { finish(nil) }
            }.store(in: &tokens)
            // And never hang the caller if neither signal ever fires (offline, no cached style).
            Task { try? await Task.sleep(for: .seconds(25)); finish(nil) }
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

    /// Mean gap between consecutive points, in meters — separates dense real-GPS captures (2–5m per
    /// fix) from sparse street-following route geometry (tens of meters per vertex), which must be
    /// drawn exactly, never smoothed.
    private static func meanSpanMeters(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<coords.count {
            total += CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                .distance(from: CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude))
        }
        return total / Double(coords.count - 1)
    }

    /// Linear interpolation between two colours (for the route gradient).
    private static func lerp(_ a: UIColor, _ b: UIColor, _ t: Double) -> UIColor {
        var (ar, ag, ab, aa): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let f = CGFloat(min(1, max(0, t)))
        return UIColor(red: ar + (br - ar) * f, green: ag + (bg - ag) * f, blue: ab + (bb - ab) * f, alpha: aa + (ba - aa) * f)
    }
}
