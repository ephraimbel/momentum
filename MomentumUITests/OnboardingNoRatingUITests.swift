import XCTest

/// Guideline 5.6.3 — "don't require or encourage customers to submit a rating." This app was once
/// rejected for a rating beat in onboarding.
///
/// A rating beat DOES ship again, deliberately, as the last step before the paywall (see the warning
/// on `OnboardingFlow.rateUsStep`). So the old assertion — "no rating ask anywhere in onboarding" —
/// no longer describes the product, and a test that asserts a shipped feature away is worse than no
/// test. What this pins instead are the two properties that keep the beat defensible:
///
///   1. It never appears BEFORE the athlete has their plan. No rating ask on the way through setup —
///      only after the reveal, once there's something to have an opinion about.
///   2. It is never required. "Not now" is a real, equally-reachable control that continues the flow.
///
/// If a submission is ever rejected over this again, the fix is to delete the `.rateUs` step — and
/// this test with it, not to weaken it further.
final class OnboardingNoRatingUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testRatingAskIsSkippableAndNeverPrecedesThePlan() {
        let app = XCUIApplication()
        // Land on the notifications step — after the reveal, before the rating beat.
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
        XCTAssertFalse(app.buttons["Rate momentum"].exists, "No rating ask on the notifications step.")
        maybeLater.tap()

        // Location step: still no rating ask. Its CTA is "Continue" — it must NOT promise an ending,
        // since the rating beat, the paywall and the account beat all still follow (2026-07-28).
        let locationContinue = app.buttons["Continue"]
        XCTAssertTrue(locationContinue.waitForExistence(timeout: 10), "Expected the location step.")
        XCTAssertFalse(app.buttons["Rate momentum"].exists, "No rating ask on the location step.")
        XCTAssertFalse(app.buttons["Start training"].exists,
                       "The location step must not claim to end onboarding — three beats follow it.")
        locationContinue.tap()

        // The rating beat — the ask auto-presents (owner call 2026-08-20), so the page carries
        // NO rating button at all; its only control is Continue, which must always be reachable.
        let planReady = app.staticTexts["Your plan is ready"]
        XCTAssertTrue(planReady.waitForExistence(timeout: 10), "Expected the rating beat after the location step.")
        XCTAssertFalse(app.buttons["Rate momentum"].exists,
                       "The beat presents Apple's alert itself — no bespoke rating button.")
        // The auto-presented StoreKit alert DOES render on simulators (observed 2026-08-20) and
        // its dismiss button is "Not Now" (capital N — not our old skip's label). Dismiss it the
        // way a human would, THEN the page's Continue must be reachable.
        let reviewNotNow = app.buttons["Not Now"]
        if reviewNotNow.waitForExistence(timeout: 4) { reviewNotNow.tap() }
        let rateContinue = app.buttons["Continue"]
        XCTAssertTrue(rateContinue.waitForExistence(timeout: 5), "Continue must exist on the rating beat.")
        XCTAssertTrue(rateContinue.isHittable, "Continue must be reachable — never a required rating.")
        rateContinue.tap()

        // Declining carries on into the app (this athlete is seeded Pro, so the wall stands down).
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20),
                      "Declining the rating ask must continue the flow, not block it.")
    }
}
