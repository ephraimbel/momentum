import SwiftUI

/// The signature iridescent surface (PRD §5.2, §18). A soft, holographic oil-slick.
///
/// iOS 18+ `MeshGradient` whose interior control points drift slowly (~8s loop) via
/// `TimelineView` for the "light catching foil" effect. Honors **Reduce Motion** by
/// holding a static state. **Earned accent only** — use exclusively on ring fills, PR
/// sweeps, the live route accent, streak/milestone surfaces, and the plan reveal.
struct IridescentView: View {
    /// Opacity multiplier, ~0.3–0.6 per the design language.
    var intensity: Double = 0.5
    /// Force a static (non-animating) state regardless of motion settings.
    var isStatic: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let loop: Double = 8 // seconds

    var body: some View {
        let frozen = isStatic || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: frozen)) { context in
            let t = frozen ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3,
                         points: points(at: t),
                         colors: colors)
                .opacity(intensity)
                .blur(radius: 6)
        }
        .accessibilityHidden(true) // decorative; meaning is always carried by text/shape too
    }

    /// 3×3 grid. Corners pinned to fill the bounds; edge-mids and center drift gently.
    private func points(at t: Double) -> [SIMD2<Float>] {
        let phase = t / loop * 2 * .pi
        func drift(_ base: Float, _ amp: Float, _ off: Double) -> Float {
            base + amp * Float(sin(phase + off))
        }
        return [
            SIMD2(0, 0),
            SIMD2(drift(0.5, 0.10, 0.0), 0),
            SIMD2(1, 0),
            SIMD2(0, drift(0.5, 0.10, 1.3)),
            SIMD2(drift(0.5, 0.08, 2.1), drift(0.5, 0.08, 0.7)),
            SIMD2(1, drift(0.5, 0.10, 3.4)),
            SIMD2(0, 1),
            SIMD2(drift(0.5, 0.10, 4.2), 1),
            SIMD2(1, 1),
        ]
    }

    /// Nine colors woven from the five low-sat holographic stops (PRD §18).
    private var colors: [Color] {
        let p = Theme.iridescent
        return [p[0], p[1], p[2],
                p[4], p[3], p[0],
                p[2], p[4], p[1]]
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        IridescentView(intensity: 0.6)
            .frame(width: 240, height: 240)
            .clipShape(Circle())
    }
}
