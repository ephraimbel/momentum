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
    /// Insets for workout snapshots. Strava-style breathing room: ~14% at the sides, more above
    /// and below (the old 34 px sides pressed the route against the tile edges — "cut off").
    /// The route still stays inside the CENTER SQUARE (y 110–770 of the 880), so the 52×52
    /// History thumbnail (a square crop of this portrait image) never clips it.
    static let workoutTileInsets = UIEdgeInsets(top: 180, left: 90, bottom: 180, right: 90)
    /// The route CARD's canvas — always Mapbox Light, the brand's clean muted monochrome basemap.
    /// A workout tile is stylized brand art, not a live map: on the colorful Standard/Streets
    /// basemaps the pastel trace drowned under restaurant pins and street colours ("tacky"), so
    /// the card renders on the clean canvas where the route reads like a Strava card. The athlete's
    /// chosen style still drives every INTERACTIVE map (Today, live tracking, the full-screen pager).
    static let tileStyle: StyleURI = .light
    /// Bump when the rendered LOOK changes — the healer re-renders stale-version snapshots so
    /// old workouts pick up the new aesthetic without being reopened.
    /// v4 (2026-07-24): route cards always on the clean Light canvas (was the athlete's live style —
    /// busy POI-pinned basemaps read tacky), solid route-purple trace (was a periwinkle→lilac
    /// gradient — iridescence is earned), generous Strava framing, a weightier stroke, and a soft
    /// dark casing that lifts the pastel trace so it never washes out over pale water.
    static let renderVersion = 4

    static func snapshot(coordinates: [CLLocationCoordinate2D],
                         size: CGSize = CGSize(width: 640, height: 360),
                         styleURI: StyleURI = .light,
                         insets: UIEdgeInsets = UIEdgeInsets(top: 26, left: 26, bottom: 26, right: 26),
                         routeWidth: CGFloat = 8) async -> Data? {
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
        // The SAME solid route purple the live map draws — one trace color everywhere. (The old
        // periwinkle→lilac gradient read as iridescence, which is reserved for earned progress.)
        // Resolved to the LIGHT variant explicitly: snapshots draw onto light basemaps, and a
        // dark-mode phone must not bake the dark-trait tint into a persisted image.
        let routeColor = UIColor(Theme.route).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light))

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
            // Casing follows the basemap so the trace lifts on any canvas:
            //  • DARK map — a near-black hairline (a white halo bloomed into a fat glow that
            //    swallowed streets, user report 2026-07-15).
            //  • LIGHT canvas (the route card) — a soft dark lift, since a white halo is invisible
            //    on near-white and the pastel periwinkle would otherwise wash out over pale water.
            //  • COLOURED map (Standard/Streets/Satellite) — the classic white halo.
            let darkBase = styleURI.rawValue.lowercased().contains("dark")
            let lightBase = styleURI == .light
            let casingColor: UIColor = darkBase ? UIColor(white: 0.07, alpha: 0.8)
                : lightBase ? UIColor(white: 0.16, alpha: 0.32)
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
                    // One solid stroke of route purple. `routeWidth` is per-surface: Strava-thin —
                    // the route is a precise trace of the streets, never a marker swipe that
                    // covers whole blocks at city zoom.
                    ctx.setLineWidth(routeWidth); ctx.setStrokeColor(routeColor.cgColor)
                    ctx.beginPath(); ctx.move(to: pts[0]); pts.dropFirst().forEach { ctx.addLine(to: $0) }
                    ctx.strokePath()
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

}
