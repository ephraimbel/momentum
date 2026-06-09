import SwiftUI

/// The glowing iridescent orb — momentum's in-app brand element. A holographic blob that feels
/// *alive*: its edge gently undulates (a wavy morph), the iridescent core slowly swirls, it breathes,
/// and the glow follows the wavy silhouette — layered over the drifting `MeshGradient`. Honors
/// Reduce Motion (holds a static round state).
struct IridescentOrb: View {
    var size: CGFloat = 120
    var glow: Bool = true

    @State private var swirl = 0.0
    @State private var breath = 1.0
    @State private var wave = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: WavyCircle { WavyCircle(phase: wave, amplitude: reduceMotion ? 0 : 0.05) }

    var body: some View {
        core
            .scaleEffect(breath)
            .shadow(color: Theme.iridescent[3].opacity(glow ? 0.5 : 0), radius: size * 0.3)
            .shadow(color: Theme.iridescent[4].opacity(glow ? 0.4 : 0), radius: size * 0.15)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { swirl = 360 }
                withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { breath = 1.05 }
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { wave = 2 * .pi }
            }
            .accessibilityHidden(true)
    }

    /// Flowing core: an over-scaled mesh that slowly rotates, clipped to the undulating blob, with a
    /// fixed top-left sheen + rim so it still reads as a lit, living sphere.
    private var core: some View {
        let coreLayer = IridescentView(intensity: 0.95)
            .scaleEffect(1.5)
            .rotationEffect(.degrees(swirl))
            .frame(width: size, height: size)
            .clipShape(shape)
        let sheen = shape.fill(
            RadialGradient(colors: [.white.opacity(0.5), .clear],
                           center: .init(x: 0.32, y: 0.28),
                           startRadius: 0, endRadius: size * 0.55)
        ).blendMode(.softLight)
        let rim = shape.stroke(.white.opacity(0.4), lineWidth: max(1, size * 0.012)).blendMode(.overlay)
        return coreLayer.overlay(sheen).overlay(rim)
    }
}

/// A circle whose radius gently undulates with angle and a rotating `phase`, giving a living,
/// "wavy" blob. Two harmonics counter-rotate so a 0…2π phase sweep loops seamlessly.
struct WavyCircle: Shape {
    var phase: Double
    var amplitude: CGFloat = 0.05      // fraction of radius
    var waves: Double = 4

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let steps = 120
        var path = Path()
        for i in 0...steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            let wob = sin(a * waves + phase) * Double(amplitude)
                    + sin(a * (waves + 2) - phase) * Double(amplitude) * 0.5
            let rr = r * (1 + CGFloat(wob))
            let pt = CGPoint(x: center.x + CGFloat(cos(a)) * rr, y: center.y + CGFloat(sin(a)) * rr)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

#Preview {
    ZStack {
        Color.white.ignoresSafeArea()
        IridescentOrb(size: 160)
    }
}
