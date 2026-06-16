import SwiftUI
import MapboxMaps

/// The brand location puck — a purple dot + white ring with a soft heading cone and a gentle pulse,
/// replacing Mapbox's default blue indicator so "you" always reads in our accent. Shared by the Today
/// map and live tracking. Apply with: `Puck2D(bearing: .heading).brandStyled()`.
enum BrandPuck {
    private static var purple: UIColor { UIColor(Theme.route) }

    /// The location dot — purple fill, white ring, soft drop shadow.
    static let dot: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { ctx in
        let c = ctx.cgContext
        let center = CGPoint(x: 14, y: 14)
        c.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        c.setFillColor(UIColor.white.cgColor)
        c.fillEllipse(in: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setFillColor(purple.cgColor)
        c.fillEllipse(in: CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11))
    }

    /// The heading cone — a soft purple wedge fanning out in the direction the athlete faces. Rotates
    /// with the puck bearing (Mapbox draws `bearingImage` centered on the location and rotated).
    static let beam: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { ctx in
        let c = ctx.cgContext
        let center = CGPoint(x: 40, y: 40)
        let radius: CGFloat = 34
        let half: CGFloat = 0.42                 // ~24° half-angle cone
        let up = -CGFloat.pi / 2
        let wedge = UIBezierPath()
        wedge.move(to: center)
        wedge.addArc(withCenter: center, radius: radius, startAngle: up - half, endAngle: up + half, clockwise: true)
        wedge.close()
        c.addPath(wedge.cgPath); c.clip()
        let colors = [purple.withAlphaComponent(0.5).cgColor, purple.withAlphaComponent(0).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        c.drawRadialGradient(gradient, startCenter: center, startRadius: 4, endCenter: center, endRadius: radius, options: [])
    }

    /// A subtle purple sonar pulse — the "alive" heartbeat under the dot.
    static let pulse = Puck2DConfiguration.Pulsing(color: purple.withAlphaComponent(0.35), radius: .constant(26))
}

extension Puck2D {
    /// Recolor the location puck to the brand: purple dot, heading cone, pulse, no accuracy ring.
    func brandStyled() -> Puck2D {
        topImage(BrandPuck.dot)
            .bearingImage(BrandPuck.beam)
            .pulsing(BrandPuck.pulse)
            .showsAccuracyRing(false)
    }
}
