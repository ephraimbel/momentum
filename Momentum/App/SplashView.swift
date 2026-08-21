import SwiftUI

/// The launch moment (owner call 2026-08-20, second take): the system's static launch screen
/// shows the white wordmark on the brand's warm dark charcoal; this view renders the IDENTICAL
/// frame the instant the app takes over, breathes one soft lavender bloom behind the word, and
/// fades away — the seamless-splash pattern Apple's guidance allows (a launch screen mirrored by
/// a matching first view; never an artificial wait). Total on-screen time ≈ 1.15s, inside the
/// ≤1.5s bar modern practice sets.
///
/// The canvas is `LaunchCanvas` — a FIXED charcoal, not the adaptive `Theme.background` — because
/// the static launch screen can't adapt either: both layers commit to the same single dark look
/// in both appearances, and the fade-out is what hands off to the app's own palette.
///
/// Reduce Motion: no bloom, no scale — the frame simply holds, then crossfades out.
struct SplashView: View {
    /// Fired once the fade-out completes, so the host can unmount the splash entirely.
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bloom = false
    @State private var gone = false

    var body: some View {
        ZStack {
            Color("LaunchCanvas").ignoresSafeArea()
            // The glow (owner call 2026-08-21, replacing a lavender radial pool that read as a
            // blob): the wordmark's OWN light — a blurred copy of the letterforms breathing in
            // beneath the sharp one, so the halo hugs the word's shape instead of imposing a
            // circle on it. White, deliberately: lavender means "tappable or happening now"
            // (scarcity rule), and a splash is neither — on charcoal, a monochrome glow is the
            // elegant read. No scale, ever; light doesn't zoom. Static at rest under Reduce
            // Motion (a held glow is fine; only the breath is motion).
            Image("LaunchWordmark")
                .blur(radius: 26)
                .opacity(bloom || reduceMotion ? 0.5 : 0)
            // EXACTLY the static launch screen's frame: the wordmark at its intrinsic 240pt
            // (owner call 2026-08-21: a touch larger — sized in the ASSET so both layers grow in
            // lockstep; sizing only one side would put a pop in the handoff),
            // centered. Rendering the same asset at the same size is what makes the system→app
            // handoff invisible; the glow then plays as the word lighting up, not as a swap.
            Image("LaunchWordmark")
        }
        .opacity(gone ? 0 : 1)
        .onAppear {
            if !reduceMotion {
                // A slow breath, not a pop — the glow arriving gently is most of its elegance.
                withAnimation(.easeInOut(duration: 0.9)) { bloom = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                withAnimation(.easeOut(duration: 0.3)) { gone = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { onFinished() }
            }
        }
        .accessibilityHidden(true)   // decorative; over in a breath
        .allowsHitTesting(false)     // never block a fast first tap
    }
}

#Preview {
    SplashView(onFinished: {})
}
