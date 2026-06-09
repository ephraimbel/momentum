import SwiftUI

/// The glowing iridescent orb — momentum's in-app brand element (cold open, building beat, empty
/// states, accents). A soft holographic sphere that catches the light; on the white canvas its
/// colored glow reads as the only color on screen (the earned-iridescence idea, §5.2).
struct IridescentOrb: View {
    var size: CGFloat = 120
    var glow: Bool = true

    var body: some View {
        IridescentView(intensity: 0.95)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(.white.opacity(0.4), lineWidth: max(1, size * 0.012))
                    .blendMode(.overlay)
            )
            // Inner sheen toward the top-left for a spherical read.
            .overlay(
                Circle()
                    .fill(
                        RadialGradient(colors: [.white.opacity(0.45), .clear],
                                       center: .init(x: 0.32, y: 0.28),
                                       startRadius: 0, endRadius: size * 0.5)
                    )
                    .blendMode(.softLight)
            )
            .shadow(color: Theme.iridescent[3].opacity(glow ? 0.5 : 0), radius: size * 0.3)
            .shadow(color: Theme.iridescent[4].opacity(glow ? 0.4 : 0), radius: size * 0.15)
            .accessibilityHidden(true)
    }
}

#Preview {
    ZStack {
        Color.white.ignoresSafeArea()
        IridescentOrb(size: 140)
    }
}
