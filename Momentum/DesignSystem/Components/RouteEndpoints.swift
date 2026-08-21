import SwiftUI
import CoreLocation
import UIKit

/// The marks every opened route wears: a **green dot where the run began** and a **checkered dot
/// where it ended** (owner design 2026-07-30, after iterating: black disc-with-flag → too heavy;
/// bare checkered glyph → busy; bare solid flag → fine but the final call is the subtler pair).
/// Two dots of the same size — the start white-edged with a green face, the finish BLACK-edged
/// around its checker (owner call, same day: white-on-white vanished on pale basemaps).
///
/// One definition, three renderers, so a route reads the same everywhere it appears:
/// * **SwiftUI** — `RouteStartMark` / `RouteFinishMark`, over `RouteSilhouette` and as
///   `RouteMapView`'s live annotations.
/// * **Core Graphics** — `draw(in:start:finish:diameter:)`, inside `RouteSnapshotter`'s overlay.
///
/// **Grids never carry marks** (owner call, same day) — they appear only on opened content, and
/// what they point at is whatever that surface draws: snapshots hide the first/last ~200m (the
/// athlete's door — `RouteSnapshotter.clippingEnds`), so the marks never reveal a home address.
enum RouteEndpoints {
    /// The one green accent (`Theme.success`) — a start dot reads as "go" in every mapping app.
    static var startColor: Color { Theme.success }
    /// Fixed near-black, NOT `Theme.ink`: these sit on a map's own palette (and inside persisted
    /// images), so they must not flip with the app's appearance the way ink does.
    static let finishColor = Color(white: 0.09)
    /// Checkerboard resolution across the finish dot's inner face. 4 reads as "finish line" without
    /// dissolving into texture at the 12pt display size.
    static let checkerCells = 4
    /// Inner face (colored fill / checker) as a fraction of the outer white-ring circle.
    static let innerFraction: CGFloat = 0.68
    /// The finish dot's white band as a fraction of its BLACK outer circle (owner call 2026-07-30:
    /// the white-edged finish dot vanished on pale basemaps — the outermost line is now black, with
    /// this thin white separator keeping the checker legible inside it). Start keeps its white
    /// edge; its green face carries the contrast.
    static let finishWhiteFraction: CGFloat = 0.8

    /// Start and finish within one mark of each other = a loop. Only the finish dot draws — the
    /// checkered dot on the spot says "started and finished here"; stacking both just made the
    /// green bleed through the pattern.
    static func isLoop(_ start: CGPoint, _ finish: CGPoint, diameter: CGFloat) -> Bool {
        hypot(start.x - finish.x, start.y - finish.y) < diameter
    }

    // MARK: Core Graphics (map snapshots)

    static func draw(in ctx: CGContext, start: CGPoint, finish: CGPoint, diameter d: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if !isLoop(start, finish, diameter: d) {
            ring(ctx, center: start, diameter: d)
            fill(ctx, center: start, diameter: d * innerFraction, color: UIColor(startColor))
        }
        // Finish: black outermost line → thin white band → checker face.
        ctx.setShadow(offset: CGSize(width: 0, height: d * 0.06), blur: d * 0.22,
                      color: UIColor.black.withAlphaComponent(0.28).cgColor)
        fill(ctx, center: finish, diameter: d, color: UIColor(finishColor))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        fill(ctx, center: finish, diameter: d * finishWhiteFraction, color: .white)
        checker(ctx, center: finish, diameter: d * innerFraction)
    }

    /// The shared base: a white dot with a soft shadow — the ring is what keeps either mark
    /// legible over parks, water, and dark basemaps alike.
    private static func ring(_ ctx: CGContext, center: CGPoint, diameter d: CGFloat) {
        ctx.setShadow(offset: CGSize(width: 0, height: d * 0.06), blur: d * 0.22,
                      color: UIColor.black.withAlphaComponent(0.28).cgColor)
        fill(ctx, center: center, diameter: d, color: .white)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private static func fill(_ ctx: CGContext, center: CGPoint, diameter: CGFloat, color: UIColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                   width: diameter, height: diameter))
    }

    /// The finish face: a checkerboard clipped to the inner circle (white cells are the ring's
    /// white showing through).
    private static func checker(_ ctx: CGContext, center: CGPoint, diameter d: CGFloat) {
        let face = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        ctx.saveGState()
        ctx.addEllipse(in: face)
        ctx.clip()
        ctx.setFillColor(UIColor(finishColor).cgColor)
        let cell = d / CGFloat(checkerCells)
        for row in 0..<checkerCells {
            for col in 0..<checkerCells where (row + col).isMultiple(of: 2) {
                ctx.fill(CGRect(x: face.minX + CGFloat(col) * cell,
                                y: face.minY + CGFloat(row) * cell,
                                width: cell, height: cell))
            }
        }
        ctx.restoreGState()
    }
}

// MARK: - SwiftUI (silhouette overlays + live-map annotations)

/// The same two marks, laid over a `RouteSilhouette` in the identical projection — so a page's
/// instant placeholder already shows the start and finish, and nothing shifts when the map
/// snapshot crossfades in behind it.
struct RouteEndpointMarks: View {
    let coords: [CLLocationCoordinate2D]
    /// Must match the silhouette's inset, or the marks land off the line.
    var inset: CGFloat = 0
    /// Overrides the width-derived size.
    var diameter: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size).insetBy(dx: inset, dy: inset)
            let pts = RouteSilhouette.points(coords, in: rect)
            if let start = pts.first, let finish = pts.last, pts.count > 1 {
                let d = diameter ?? min(22, max(9, geo.size.width * 0.075))
                ZStack(alignment: .topLeading) {
                    if !RouteEndpoints.isLoop(start, finish, diameter: d) {
                        RouteStartMark(diameter: d).position(start)
                    }
                    RouteFinishMark(diameter: d).position(finish)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // the surrounding card carries the description
    }
}

/// Where the run began: a green dot in a white ring.
struct RouteStartMark: View {
    var diameter: CGFloat = 12

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle()
                    .fill(RouteEndpoints.startColor)
                    .frame(width: diameter * RouteEndpoints.innerFraction,
                           height: diameter * RouteEndpoints.innerFraction)
            }
            .shadow(color: .black.opacity(0.28), radius: diameter * 0.22, y: diameter * 0.06)
            .accessibilityLabel("Start")
    }
}

/// Where the run ended: the same dot wearing the finish-line checker — subtle, and unmistakably
/// "finish" next to the green "go".
struct RouteFinishMark: View {
    var diameter: CGFloat = 12

    var body: some View {
        let face = diameter * RouteEndpoints.innerFraction
        Circle()
            .fill(RouteEndpoints.finishColor)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle()
                    .fill(.white)
                    .frame(width: diameter * RouteEndpoints.finishWhiteFraction,
                           height: diameter * RouteEndpoints.finishWhiteFraction)
            }
            .overlay {
                Canvas { ctx, size in
                    let cells = RouteEndpoints.checkerCells
                    let cell = size.width / CGFloat(cells)
                    for row in 0..<cells {
                        for col in 0..<cells where (row + col).isMultiple(of: 2) {
                            ctx.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                                 width: cell, height: cell)),
                                     with: .color(RouteEndpoints.finishColor))
                        }
                    }
                }
                .frame(width: face, height: face)
                .clipShape(Circle())
            }
            .shadow(color: .black.opacity(0.28), radius: diameter * 0.22, y: diameter * 0.06)
            .accessibilityLabel("Finish")
    }
}
