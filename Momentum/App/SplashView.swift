import SwiftUI

/// The launch moment (owner ask 2026-08-20): the system's static launch screen shows the glass
/// runner centered on porcelain; this view renders the IDENTICAL frame the instant the app takes
/// over, breathes one soft lavender bloom behind the mark, and fades away — the seamless-splash
/// pattern Apple's guidance allows (a launch screen mirrored by a matching first view; never an
/// artificial wait). Total on-screen time ≈ 1.15s, inside the ≤1.5s bar modern practice sets.
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
            Theme.background.ignoresSafeArea()
            // The bloom: one soft lavender pool waking behind the mark — brand, not decoration,
            // and the page's only motion. Static under Reduce Motion.
            Circle()
                .fill(
                    RadialGradient(colors: [Theme.purple.opacity(0.16), .clear],
                                   center: .center, startRadius: 10, endRadius: 150)
                )
                .frame(width: 300, height: 300)
                .opacity(bloom ? 1 : 0)
                .scaleEffect(bloom ? 1 : 0.7)
            // EXACTLY the static launch screen's frame: the 96pt mark, centered in the safe
            // area. The soft shadow wakes WITH the bloom — the glass icon alone reads ghostly
            // on porcelain — so the handoff plays as the mark lighting up, not as a swap.
            BrandMark(size: 96)
                .shadow(color: .black.opacity(bloom ? 0.28 : 0), radius: 18, y: 10)
        }
        .opacity(gone ? 0 : 1)
        .onAppear {
            if !reduceMotion {
                withAnimation(.easeOut(duration: 0.45)) { bloom = true }
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
