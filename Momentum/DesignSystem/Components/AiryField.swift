import SwiftUI

/// The page's background as a CONTINUOUS, MULTI-HUE field: mostly canvas, with faint,
/// well-separated pools of different hues, so the eye reads air rather than colour.
///
/// It exists because the paywall and the data pages kept drifting apart. The rules that make it
/// work, learned the hard way (owner calls 2026-08-28):
///
///  • **Separate the hues.** Four blooms from the lavender family at full strength read as one
///    purple wash, not as air. Spread them far apart and let a non-lavender note in — the green
///    here is `Health.recoveryInk`, the one the system already owns.
///  • **Keep every bloom's frame square and wider than its own `endRadius`.** A radial gradient
///    that is still coloured when it meets its box renders as a hard-edged RECTANGLE, which is
///    exactly what a bloom sized to a text block did.
///  • **`intensity` is the only knob.** The paywall wears it at 1; a dense page of cards wants
///    roughly half, or the field competes with the content sitting on it.
struct AiryField: View {
    /// 1 = the paywall's strength. Content-dense pages should sit near 0.5.
    var intensity: Double = 1
    /// False = the blooms ALONE, over whatever is already behind them. Onboarding paints a lighter
    /// canvas than `Theme.background` (`OnboardingStyle.canvas`), so a field that brought its own
    /// base would sit on those pages as a faintly different-toned rectangle. Every existing caller
    /// leaves this true and is unaffected.
    var paintsBackground: Bool = true

    private func wash(_ c: Color, _ o: Double, _ at: UnitPoint, _ r: CGFloat) -> some View {
        let a = o * intensity
        return RadialGradient(colors: [c.opacity(a), c.opacity(a * 0.35), .clear],
                              center: at, startRadius: 0, endRadius: r)
    }

    var body: some View {
        ZStack {
            if paintsBackground { Theme.background }
            wash(Theme.iridescent[0], 0.15, UnitPoint(x: 0.18, y: 0.16), 300)   // lavender
            wash(Theme.iridescent[1], 0.18, UnitPoint(x: 0.96, y: 0.40), 300)   // sky
            wash(Theme.Health.recoveryInk, 0.07, UnitPoint(x: 0.80, y: 0.62), 260)
            wash(Theme.iridescent[2], 0.13, UnitPoint(x: 0.04, y: 0.70), 280)   // rose
            wash(Theme.iridescent[4], 0.10, UnitPoint(x: 0.55, y: 0.95), 300)   // orchid
        }
        // Decoration only. Without this the field took part in hit testing behind a scrolling
        // page and cards stopped reporting as hittable, which failed four Progress UI tests
        // while the page still LOOKED right (2026-08-28). A background must never answer a touch.
        .allowsHitTesting(false)
        // `ignoresSafeArea` belongs to the caller, not in here: applied inside a `.background`
        // it expands the backdrop's own footprint and drags the hosting geometry with it.
    }
}
