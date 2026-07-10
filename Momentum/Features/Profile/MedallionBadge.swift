import SwiftUI

/// A 3D achievement medallion (the Runna/Strava badge treatment, in momentum's language): a
/// machined silver face with a real sense of depth — iridescent rim (earned accent), inner dish
/// with an inset shadow, an embossed ink icon, and a glass specular sweep — floating on a soft
/// drop shadow. Pure gradients, no image assets, fully static (grids of these must stay 60fps).
struct MedallionBadge: View {
    let icon: String
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            // Base coin + drop shadow — the medal sits ABOVE the page.
            Circle()
                .fill(Self.face)
                .shadow(color: .black.opacity(0.16), radius: size * 0.09, y: size * 0.055)

            // Earned iridescent rim, machined: a bright edge line outside, a dark seat inside.
            Circle()
                .strokeBorder(Self.rim, lineWidth: size * 0.062)
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 0.75))
                .overlay(
                    Circle().inset(by: size * 0.062)
                        .strokeBorder(.black.opacity(0.25), lineWidth: 1)
                )

            // Inner dish: recessed via an inset shadow, so the face reads concave against the rim.
            Circle()
                .inset(by: size * 0.062)
                .fill(Self.dish
                    .shadow(.inner(color: .black.opacity(0.28), radius: size * 0.07, y: size * 0.045))
                    .shadow(.inner(color: .white.opacity(1.0), radius: size * 0.025, y: -size * 0.025)))

            // Embossed icon: struck into the metal — light catches the top edge, shade falls below.
            // FIXED ink, not Theme.ink: the medal is a physical object whose engraving doesn't
            // re-anodize in dark mode (adaptive ink turned white-on-silver and vanished).
            Image(systemName: icon)
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: "1C1C22").opacity(0.92),
                                            Color(hex: "1C1C22").opacity(0.62)],
                                   startPoint: .top, endPoint: .bottom))
                .shadow(color: .white.opacity(0.9), radius: 0.5, y: 0.8)
                .shadow(color: .black.opacity(0.22), radius: 1, y: -0.6)

            // Specular sweep: one soft glass highlight across the upper face — the "3D" tell.
            Circle()
                .inset(by: size * 0.09)
                .fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.55), location: 0),
                    .init(color: .white.opacity(0.06), location: 0.42),
                    .init(color: .clear, location: 0.55),
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // decorative — the label lives on the badge cell
    }

    // MARK: Materials

    /// Brushed-silver coin face.
    private static let face = LinearGradient(stops: [
        .init(color: Color(red: 0.99, green: 0.99, blue: 1.00), location: 0),
        .init(color: Color(red: 0.84, green: 0.84, blue: 0.88), location: 0.5),
        .init(color: Color(red: 0.92, green: 0.92, blue: 0.95), location: 0.72),
        .init(color: Color(red: 0.72, green: 0.72, blue: 0.78), location: 1),
    ], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The dish carries the metal: light crown, shaded base — the inset shadows land on this.
    private static let dish = LinearGradient(stops: [
        .init(color: Color(red: 0.98, green: 0.98, blue: 1.00), location: 0),
        .init(color: Color(red: 0.90, green: 0.90, blue: 0.94), location: 0.55),
        .init(color: Color(red: 0.83, green: 0.83, blue: 0.88), location: 1),
    ], startPoint: .top, endPoint: .bottom)

    /// The earned accent: an iridescent metal band, angle-swept like real anodization.
    private static let rim = AngularGradient(
        colors: Theme.iridescent + [Theme.iridescent.first ?? .purple],
        center: .center, angle: .degrees(-50))
}

/// One badge cell for the Highlights showcase: medallion + the achievement's number + what it is.
struct BadgeCell: View {
    let item: ProfileHighlights.Highlight

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            MedallionBadge(icon: item.systemImage)
            VStack(spacing: 1) {
                Text(item.value)
                    .font(.display(17, weight: .black)).monospacedDigit()
                    .foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.6)
                Text(item.title)
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.4)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(item.value)")
    }
}
