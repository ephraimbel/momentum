import XCTest

/// Guideline 5.6.3: the app must NOT ask for a rating on first launch or during onboarding. It once
/// did — a "Rate momentum" beat was the last onboarding step, which got the app rejected. This test
/// replaces the old one that verified that (now removed) beat, and pins the corrected behaviour:
/// onboarding ends straight into the app, with no rating ask anywhere in the flow.
final class OnboardingNoRatingUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testOnboardingEndsInTheAppWithNoRatingAsk() {
        let app = XCUIApplication()
        // Land on the notifications step (near the end); the two steps to the finish carry no rating.
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

        // The removed beat's copy must never appear at any point in the flow.
        XCTAssertFalse(app.buttons["Rate momentum"].exists, "A rating ask must not appear during onboarding.")
        XCTAssertFalse(app.staticTexts["Help the next runner"].exists, "The onboarding rating beat must be gone.")

        // Notifications step → primers step.
        let maybeLater = app.buttons["Maybe later"]
        XCTAssertTrue(maybeLater.waitForExistence(timeout: 15), "Expected the notifications step.")
        maybeLater.tap()

        // The terminal step's CTA is "Start training" — not a rating ask.
        let startTraining = app.buttons["Start training"]
        XCTAssertTrue(startTraining.waitForExistence(timeout: 10),
                      "Onboarding should end on 'Start training', not a rating beat.")
        XCTAssertFalse(app.buttons["Rate momentum"].exists, "Still no rating ask on the final step.")
        startTraining.tap()
        app.tap()   // dismiss the location prompt if it surfaces

        // Lands in the app, and no rating ask was raised on the way in.
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 10),
                      "'Start training' should land in the app with the tab bar visible.")
        XCTAssertFalse(app.buttons["Rate momentum"].exists,
                       "No rating ask may fire on first entry into the app.")
    }
}
