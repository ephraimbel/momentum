import SwiftUI

/// The beat between the plan reveal and checkout: one quiet page asking the athlete to leave an
/// App Store review, with the native sheet raised for them on arrival.
///
/// **Shape (owner call 2026-09-05, the third time this has been asked for with the 5.6.3 history
/// spelled out).** The ask is a page of its own now, and the sheet comes up without a tap — the
/// owner's words: "make sure the review pops up when they get to the page, they shouldn't have to
/// click a button for the review to pop up". What that costs and what must therefore stay true:
///
/// - **Nothing is gated.** `Continue` is live from the first frame, it is the only forward action,
///   and it is never disabled, never delayed, never hidden behind the sheet. An athlete who
///   swipes the sheet away sees a finished page and one button.
/// - **There is no custom rating UI.** No stars to tap, no "do you like momentum?" fork, no
///   branch that routes unhappy athletes somewhere else. Guideline 5.6.3 is specifically about
///   *that* pattern; the only rating surface here is Apple's own `requestReview()`.
/// - **The page tells the truth while the sheet is up.** iOS decides whether to show anything and
///   never tells us what happened, so the copy settles into a thank-you either way rather than
///   claiming a review exists.
/// - **One slot, honestly spent.** Arrival calls `AppReview.recordOnboardingAsk()`, which burns
///   one of Apple's three yearly asks WITHOUT latching "rated" — so the in-app earned cards pick
///   up at the 5th and 15th logged item instead of arriving the next morning.
///
/// The 0.5s wait before raising the sheet is load-bearing and is the same beat `WorkoutRunner`
/// waits out: a system sheet presented over a view that is still animating in is silently dropped
/// by iOS. `OnboardingReviewUITests` pins the invariants above.
struct OnboardingReviewView: View {
    /// Raises the native App Store sheet. Injected rather than read from the environment here so
    /// the flow keeps one `@Environment(\.requestReview)` and the page stays previewable.
    var ask: () -> Void
    /// False only under `--review-no-ask`, so a UI test can read the page itself without a system
    /// sheet sitting on top of every query. Never false in a shipping run.
    var raisesAsk = true
    var onContinue: () -> Void

    var body: some View {
        OnboardingHeroPage {
            Spacer(minLength: Theme.Space.md)

            // The app itself is what we're asking about, so the app's own mark is the hero — lit
            // the way the permission beats light their glyph, so this page belongs to the set.
            BrandMark(size: 92)
                .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
                .shadow(color: Theme.iridescent[1].opacity(0.42), radius: 34, y: 14)
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
            // Live on the first frame and gated on nothing. This is the invariant that keeps the
            // page out of the shape Apple rejected in 2026-07: the ask shares the screen, it never
            // owns the way forward.
            OnboardingCTA(title: "Continue", action: onContinue)
                .accessibilityIdentifier("onboarding.review.continue")
                .padding(.top, Theme.Space.sm)
                .onboardingEntrance(0.26)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Belongs to the page: a fast Continue before the wait is out cancels the ask rather
            // than firing it over the checkout that replaced this screen.
            guard raisesAsk else { return }
            do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            guard !Task.isCancelled else { return }
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
