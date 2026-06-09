import SwiftUI

/// The glowing iridescent orb — momentum's in-app brand element. A holographic sphere that feels
/// *alive*: the iridescent core slowly swirls, the orb gently breathes, and its glow pulses with
/// the breath — layered over the drifting `MeshGradient`. Honors Reduce Motion (holds static).
struct IridescentOrb: View {
    var size: CGFloat = 120
    var glow: Bool = true

    @State private var swirl = 0.0
    @State private var breath = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        core
            .scaleEffect(breath)
            .shadow(color: Theme.iridescent[3].opacity(glow ? 0.5 : 0), radius: size * 0.3)
            .shadow(color: Theme.iridescent[4].opacity(glow ? 0.4 : 0), radius: size * 0.15)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { swirl = 360 }
                withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { breath = 1.05 }
            }
            .accessibilityHidden(true)
    }

    /// Flowing core: an over-scaled mesh that slowly rotates, clipped to the sphere, with a fixed
    /// top-left sheen + rim so it reads as a lit sphere (the sheen does not rotate with the core).
    private var core: some View {
        let coreLayer = IridescentView(intensity: 0.95)
            .scaleEffect(1.5)
            .rotationEffect(.degrees(swirl))
            .frame(width: size, height: size)
            .clipShape(Circle())
        let sheen = Circle().fill(
            RadialGradient(colors: [.white.opacity(0.5), .clear],
                           center: .init(x: 0.32, y: 0.28),
                           startRadius: 0, endRadius: size * 0.55)
        ).blendMode(.softLight)
        let rim = Circle().strokeBorder(.white.opacity(0.4), lineWidth: max(1, size * 0.012)).blendMode(.overlay)
        return coreLayer.overlay(sheen).overlay(rim)
    }
}

#Preview {
    ZStack {
        Color.white.ignoresSafeArea()
        IridescentOrb(size: 160)
    }
}
