import XCTest

/// Guideline 5.6.3 — "don't require or encourage customers to submit a rating." This app was once
/// rejected for a rating beat in onboarding.
///
/// A rating STEP shipped again from 2026-07-26 and was **removed 2026-08-22**: it asked for a
/// rating from someone who had never used the app, and it sat directly between the plan reveal and
/// the checkout, spending the athlete's patience at the exact moment the flow needed it.
///
/// Since 2026-08-28 onboarding carries one quiet LINK — "Leave a review to help more runners join
/// momentum", above the plan reveal's CTA (owner call, made with this history spelled out). The
/// line between that and the thing Apple rejected is the whole point of this test, so it is drawn
/// here rather than left to memory:
///
///  • a link the athlete may tap is allowed; a card raised over them is not,
///  • it must never call `requestReview()` — no system sheet before the first workout exists,
///  • nothing may block or gate Continue on it,
///  • and no rating surface may appear on ANY later beat (notifications, location, the paywall
///    hand-off), which is where the removed step used to live.
///
/// The engagement-gated pre-prompt (`AppReview.shouldRequestReview` + `RatingPromptView`) still
/// belongs only to the earned moments after a saved workout or a logged meal.
final class OnboardingNoRatingUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// The reveal's line is a link, and it is the ONLY rating surface in the flow: no modal card,
    /// and Continue works whether or not it is ever tapped.
    func testTheRevealsReviewLineIsALinkAndNotAPrompt() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--onboarding", "--onboarding-reveal", "--reveal-runs"]
        app.launch()

        let line = app.buttons["Leave a review for momentum on the App Store"]
        XCTAssertTrue(line.waitForExistence(timeout: 20), "Expected the reveal's review line.")
        // A card raised over the athlete is the 5.6.3 shape. A line sitting under the CTA is not.
        XCTAssertFalse(app.buttons["Rate momentum"].exists,
                       "Onboarding must never raise the rating CARD — only the quiet line.")
        XCTAssertFalse(app.staticTexts["Enjoying momentum?"].exists,
                       "The engagement pre-prompt belongs to the earned moments, not onboarding.")
        // Nothing about the ask may gate the flow.
        let cta = app.buttons["This looks great"]
        XCTAssertTrue(cta.exists, "The reveal's CTA must stand on its own.")
        XCTAssertTrue(cta.isHittable, "Continue must never wait on the review line.")
    }

    func testNoRatingAskAnywhereAfterTheReveal() {
        let app = XCUIApplication()
        // Land on the notifications step — the first beat after the plan reveal, so everything from
        // here to the paywall is the stretch a rating beat would ever have lived in.
        app.launchArguments = ["--seed-demo", "--onboarding", "--onboarding-notifications"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // Notifications step: no rating ask here.
        let maybeLater = app.buttons["Maybe later"]
        XCTAssertTrue(maybeLater.waitForExistence(timeout: 15), "Expected the notifications step.")
        assertNoRatingSurface(app, on: "the notifications step")
        maybeLater.tap()

        // Location step: still no rating ask. Its CTA is "Continue" — it must NOT promise an ending,
        // since the paywall and the account beat both still follow it.
        let locationContinue = app.buttons["Continue"]
        XCTAssertTrue(locationContinue.waitForExistence(timeout: 10), "Expected the location step.")
        assertNoRatingSurface(app, on: "the location step")
        XCTAssertFalse(app.buttons["Start training"].exists,
                       "The location step must not claim to end onboarding — two beats follow it.")
        locationContinue.tap()

        // Continue now hands STRAIGHT to the paywall gate. No screen in between, and in particular
        // no "Your plan is ready" rating page — that copy was the removed beat's headline, so its
        // absence is the specific regression guard.
        XCTAssertFalse(app.staticTexts["Your plan is ready"].waitForExistence(timeout: 4),
                       "The rating beat must not come back between the primers and the paywall.")
        assertNoRatingSurface(app, on: "the hand-off to the paywall")

        // This athlete is seeded Pro, so the wall stands down and the flow completes into the app.
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20),
                      "Onboarding must complete into the app.")
    }

    /// No bespoke rating control, and none of the removed beat's furniture, on the screen in view.
    private func assertNoRatingSurface(_ app: XCUIApplication, on screen: String) {
        XCTAssertFalse(app.buttons["Rate momentum"].exists, "No rating ask on \(screen).")
        XCTAssertFalse(app.staticTexts["A quick rating helps the next runner find theirs."].exists,
                       "No rating copy on \(screen).")
    }
}
