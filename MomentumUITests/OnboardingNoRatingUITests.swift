import XCTest

/// Guideline 5.6.3 — "don't require or encourage customers to submit a rating." This app was once
/// rejected for a rating beat in onboarding.
///
/// A rating beat shipped again anyway from 2026-07-26 (deliberately, at the owner's direction) as
/// the last screen before the paywall, and this test was weakened to accommodate it. It was
/// **removed 2026-08-22** during the conversion-funnel work: it asked for a rating from someone who
/// had never used the app, and it sat directly between the plan reveal and the checkout, spending
/// the athlete's patience at the exact moment the flow needed it. So the original assertion is
/// restored, and it is the strong one — **no rating ask anywhere in onboarding.**
///
/// The only rating ask that ships is the engagement-gated pre-prompt after a first saved workout
/// (`AppReview.shouldRequestReview` + `RatingPromptView`). If someone proposes an onboarding rating
/// beat again, this test is the argument against it.
final class OnboardingNoRatingUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testNoRatingAskAnywhereInOnboarding() {
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
