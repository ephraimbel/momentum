import SwiftUI

/// An optional native review ask immediately after the athlete leaves their plan reveal.
/// StoreKit decides whether to display its sheet; Continue never depends on a rating or response.
/// Only artwork enters with motion. The CTA is visible and usable from its first frame.
struct OnboardingReviewView: View {
    /// Raises the native App Store sheet. Injected rather than read from the environment here so
    /// the flow keeps one `@Environment(\.requestReview)` and the page stays previewable.
    var ask: () -> Void
    /// False only under `--review-no-ask`, so a UI test can read the page itself without a system
    /// sheet sitting on top of every query. Never false in a shipping run.
    var raisesAsk = true
    var onContinue: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var continued = false
    @State private var requested = false

    var body: some View {
        OnboardingHeroPage {
            Spacer(minLength: Theme.Space.md)

            // The app itself is what we're asking about, so the app's own mark is the hero — lit
            // the way the permission beats light their glyph, so this page belongs to the set.
            BrandMark(size: 92)
                .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
                .padding(.bottom, Theme.Space.xs)
                .onboardingEntrance(0.02, lift: 10)

            // ONE copy state, on purpose. The obvious move is to settle into "Thanks for leaving
            // a review" once the sheet has been up, but iOS tells us nothing about what happened
            // in it — the athlete may have tapped Not Now, or may never have been shown anything
            // at all — so a thank-you would be the app claiming something it cannot know. The
            // page states the ask and stays stated; the sheet does the asking.
            OnboardingHeading(
                title: "Help the next runner find momentum",
                subtitle: "Runners find momentum through other runners. A quick review puts it in front of the next one.",
                alignment: .center)
                .padding(.top, Theme.Space.md)
                .padding(.horizontal, Theme.Space.sm)
                .onboardingEntrance(0.08)

            Spacer(minLength: Theme.Space.md)
        } actions: {
            // Never animate, disable, or delay the way forward while waiting for StoreKit.
            OnboardingCTA(title: "Continue") {
                continued = true
                // The flow deduplicates checkout/completion. Keep this action usable if a
                // system-driven cover dismissal returns here without completing onboarding.
                onContinue()
            }
                .accessibilityIdentifier("onboarding.review.continue")
                .padding(.top, Theme.Space.sm)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: scenePhase) {
            // Belongs to the page: a fast Continue before the wait is out cancels the ask rather
            // than firing it over the checkout that replaced this screen.
            guard raisesAsk, scenePhase == .active, !requested, !continued else { return }
            do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            guard !Task.isCancelled, !continued, !requested, scenePhase == .active else { return }
            requested = true
            AppReview.recordOnboardingAsk()
            ask()
        }
    }

}

#Preview("Review beat") {
    ZStack {
        OnboardingCanvas()
        OnboardingReviewView(ask: {}, raisesAsk: false, onContinue: {})
    }
}
