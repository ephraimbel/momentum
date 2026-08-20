import SwiftUI

/// The "Enjoying momentum?" pre-prompt — a clean, centered soft-ask shown ONCE, at the
/// finished-workout peak (after the athlete's first genuine save; see `AppReview`). This is NOT
/// the native App Store rating alert — Apple owns that and it can't be styled. This is the card
/// that routes a happy athlete INTO the native ask (its positive branch fires the caller's
/// `requestReview`). Never shown during onboarding or before real engagement (guideline 5.6.3).
///
/// A centered modal over a dimmed backdrop — minimal, professional, one accent: the map-tracing
/// lavender (`Theme.proLavender`). No iridescence (that stays earned-for-progress).
struct RatingPromptView: View {
    /// Positive branch — the caller triggers the native `requestReview` (after this closes).
    let onRate: () -> Void
    /// "Maybe later", tap-outside, or an interactive dismiss.
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    /// `route` (the lavender) is LIGHT in both appearances, so a theme-flipping ink would vanish on
    /// it in dark mode — the CTA label is a fixed deep indigo that reads on lavender either way.
    private let onLavender = Color(hex: "232042")

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.40 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            card
                .frame(maxWidth: 380)
                .padding(.horizontal, Theme.Space.xl)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown ? 1 : 0.94)
        }
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { shown = true } }
        }
    }

    private func dismiss() {
        Haptics.light()
        onDismiss()
    }

    private var card: some View {
        VStack(spacing: 0) {
            stars

            Text("Enjoying momentum?")
                .font(.display(23, weight: .heavy)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Space.lg)

            Text("A quick rating helps more runners find their plan.")
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.sm)

            rateButton
                .padding(.top, Theme.Space.xl)

            Button { dismiss() } label: {
                Text("Maybe later")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Space.sm)
        }
        .padding(Theme.Space.xl)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.background))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
    }

    /// Five lavender stars — the single accent, calm staggered fade-in (Reduce Motion lands at rest).
    private var stars: some View {
        HStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: "star.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Theme.proLavender)
                    .opacity(shown ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3).delay(0.12 + Double(i) * 0.04),
                               value: shown)
            }
        }
        .accessibilityHidden(true)
    }

    /// Lavender pill with a fixed deep-indigo label — the one strong color moment; text stays legible
    /// on the light fill in both themes.
    private var rateButton: some View {
        Button {
            Haptics.success()
            onRate()
        } label: {
            Text("Rate momentum")
                .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(onLavender)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.proLavender))
        }
        .buttonStyle(PressableScaleStyle())
    }
}
