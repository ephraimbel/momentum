import SwiftUI

/// The "Enjoying momentum?" pre-prompt — a clean, on-brand soft-ask shown ONCE, at the
/// finished-workout peak (after the athlete's first genuine save; see `AppReview`). This is NOT
/// the native App Store rating alert — Apple owns that and it can't be styled. This is the card
/// that routes a happy athlete INTO the native ask (its positive branch fires the caller's
/// `requestReview`). Never shown during onboarding or before real engagement (guideline 5.6.3).
///
/// Presented as a fitted sheet by `WorkoutRunner`, after the summary cover has fully dismissed.
struct RatingPromptView: View {
    /// Positive branch — the caller triggers the native `requestReview` (after this sheet dismisses).
    let onRate: () -> Void
    /// "Maybe later" or an interactive swipe-down.
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var starsIn = false

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            stars
            VStack(spacing: Theme.Space.sm) {
                Text("Enjoying momentum?")
                    .font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text("A quick rating helps other runners find their plan.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Theme.Space.xs) {
                OversizedButton(title: "Rate momentum", systemImage: "star.fill") {
                    Haptics.success()
                    onRate()
                }
                Button {
                    Haptics.light()
                    onDismiss()
                } label: {
                    Text("Maybe later")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .onAppear {
            if reduceMotion { starsIn = true }
            else { withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { starsIn = true } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enjoying momentum? A quick rating helps other runners find their plan.")
    }

    /// Five iridescent stars, popping in sequence — iridescence is the earned accent, and this rides
    /// the finished-workout achievement (Reduce Motion lands them statically).
    private var stars: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: "star.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(IridescentMaterial())
                    .scaleEffect(starsIn ? 1 : 0.4)
                    .opacity(starsIn ? 1 : 0)
                    .animation(reduceMotion ? nil
                               : .spring(response: 0.45, dampingFraction: 0.55).delay(Double(i) * 0.06),
                               value: starsIn)
            }
        }
        .padding(.top, Theme.Space.sm)
        .accessibilityHidden(true)
    }
}
