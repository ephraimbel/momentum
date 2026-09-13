import SwiftUI
import CoreLocation
import UIKit

/// Where a route lands on a canvas, and how to lay one render over another so the route does not
/// move (2026-09-13, owner report: "the route looks zoomed in, then it fixes").
///
/// Every route canvas in the app — the persisted 3:4 card, the wall tile, the full-bleed page
/// render, the live `RouteMapView` — is the same Mercator picture at a different zoom: the route's
/// bounding box fitted inside the canvas minus its insets, centred. Drawing a tile-framed image
/// `scaledToFill` onto a page therefore showed the route LARGER than the live map's fit, and the
/// map's arrival read as a zoom-out. Given the coordinates each render was framed to, the mapping
/// between the two is an exact similarity (one scale, one offset) — so the card can be placed on
/// the page with the route already exactly where the map will draw it, and the map's fade-in
/// changes nothing but sharpness.
enum RouteFraming {
    /// Web Mercator, world normalised to 0…1 on both axes, y growing downward like screen space.
    static func mercator(_ c: CLLocationCoordinate2D) -> CGPoint {
        let lat = max(-85.05112878, min(85.05112878, c.latitude))
        let x = (c.longitude + 180) / 360
        let s = sin(lat * .pi / 180)
        let y = 0.5 - log((1 + s) / (1 - s)) / (4 * .pi)
        return CGPoint(x: x, y: y)
    }

    /// A finished camera: points per Mercator world unit, and the world point at the canvas'
    /// padded centre.
    struct Fit: Equatable {
        var scale: CGFloat
        var center: CGPoint
        /// The screen point the Mercator centre sits on.
        var anchor: CGPoint
    }

    /// The Mapbox "fit these coordinates inside the padded canvas" camera, reproduced: the box
    /// is centred in the padded rect at the largest scale that keeps it inside. `maxZoom` mirrors
    /// the live map's clamp for tiny routes (world width = 512 · 2^zoom points).
    static func fit(_ coords: [CLLocationCoordinate2D], in size: CGSize,
                    insets: UIEdgeInsets, maxZoom: Double? = nil) -> Fit? {
        let pts = coords.map(mercator)
        guard let first = pts.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let padW = max(size.width - insets.left - insets.right, 1)
        let padH = max(size.height - insets.top - insets.bottom, 1)
        let spanX = max(maxX - minX, 1e-12), spanY = max(maxY - minY, 1e-12)
        var scale = min(padW / spanX, padH / spanY)
        if let maxZoom { scale = min(scale, 512 * pow(2, maxZoom)) }
        return Fit(scale: scale,
                   center: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                   anchor: CGPoint(x: insets.left + padW / 2, y: insets.top + padH / 2))
    }

    /// How to draw an image framed by `source` on a canvas that will be framed by `target`:
    /// the image's on-canvas size and centre. Both renders share the map, so a world point p
    /// sits at `anchor + (p − center) · scale` in each, and eliminating p gives one similarity.
    struct Placement: Equatable {
        var size: CGSize
        var center: CGPoint
    }

    static func placement(imageSize: CGSize, source: Fit, target: Fit) -> Placement {
        let k = target.scale / source.scale
        // The image origin lands at target.anchor − k·source.anchor + (source.center − target.center)·target.scale
        let origin = CGPoint(
            x: target.anchor.x - k * source.anchor.x + (source.center.x - target.center.x) * target.scale,
            y: target.anchor.y - k * source.anchor.y + (source.center.y - target.center.y) * target.scale)
        let size = CGSize(width: imageSize.width * k, height: imageSize.height * k)
        return Placement(size: size, center: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2))
    }

    /// The placement when the source route is not known yet (the very first frame of a page
    /// opened from the grid, before its samples have been walked): assume the common case — a
    /// loop, wide as tall, filling the padded width of both canvases — which is exact for loops
    /// and within a few points for most runs. The exact placement replaces it once coordinates
    /// land, a beat later.
    static func assumedPlacement(imageSize: CGSize, imageInsets: UIEdgeInsets,
                                 canvas: CGSize, canvasInsets: UIEdgeInsets) -> Placement {
        let srcPadW = max(imageSize.width - imageInsets.left - imageInsets.right, 1)
        let dstPadW = max(canvas.width - canvasInsets.left - canvasInsets.right, 1)
        let k = dstPadW / srcPadW
        let srcAnchor = CGPoint(x: imageInsets.left + srcPadW / 2,
                                y: imageInsets.top + (imageSize.height - imageInsets.top - imageInsets.bottom) / 2)
        let dstAnchor = CGPoint(x: canvasInsets.left + dstPadW / 2,
                                y: canvasInsets.top + (canvas.height - canvasInsets.top - canvasInsets.bottom) / 2)
        let size = CGSize(width: imageSize.width * k, height: imageSize.height * k)
        let origin = CGPoint(x: dstAnchor.x - k * srcAnchor.x, y: dstAnchor.y - k * srcAnchor.y)
        return Placement(size: size, center: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2))
    }
}

/// A route image framed for one canvas, drawn on another with the route already in its final
/// place — the stand-in a page shows until its own full-bleed render or live map arrives. The
/// sharp image is scaled and positioned by `RouteFraming`; a heavily blurred fill of the same
/// image sits behind it, so the strip the smaller frame cannot cover (top and bottom, under the
/// chrome and the scrim) reads as more map out of focus rather than a hard edge.
struct RouteStandIn: View {
    let image: UIImage
    /// The size the image was RENDERED at, in points (the card is 660×880, the wall tile 300×400).
    let imageSize: CGSize
    let imageInsets: UIEdgeInsets
    /// The coordinates the image was framed to (the clipped route for cards and tiles); nil when
    /// they are not known yet — the assumed placement is used until they are.
    var sourceCoordinates: [CLLocationCoordinate2D]?
    /// The canvas this stand-in fills, and the coordinates + insets its live map will fit.
    let canvas: CGSize
    var canvasInsets: UIEdgeInsets = RouteStandIn.pageInsets
    var targetCoordinates: [CLLocationCoordinate2D]?
    var maxZoom: Double? = RouteStandIn.pageMaxZoom

    /// `RouteMapView`'s default fit, which every full-bleed page uses.
    static let pageInsets = UIEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
    static let pageMaxZoom: Double = 17

    private var placement: RouteFraming.Placement {
        if let sourceCoordinates, let targetCoordinates,
           let source = RouteFraming.fit(sourceCoordinates, in: imageSize, insets: imageInsets),
           let target = RouteFraming.fit(targetCoordinates, in: canvas, insets: canvasInsets, maxZoom: maxZoom) {
            return RouteFraming.placement(imageSize: imageSize, source: source, target: target)
        }
        return RouteFraming.assumedPlacement(imageSize: imageSize, imageInsets: imageInsets,
                                             canvas: canvas, canvasInsets: canvasInsets)
    }

    var body: some View {
        let place = placement
        ZStack {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
                .blur(radius: 36, opaque: true)
                .overlay(Color.black.opacity(0.06))
            Image(uiImage: image).resizable()
                .frame(width: place.size.width, height: place.size.height)
                .position(place.center)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        // The refinement from the assumed placement to the exact one is a small settle, never
        // a jump: opacity/transform only, and only when coordinates land.
        .animation(.easeOut(duration: 0.2), value: place)
    }
}
