import XCTest

/// The end-of-onboarding rating beat (the last thing before the app): a calm priming screen whose
/// "Rate momentum" raises the native App Store prompt, with a "Maybe later" skip — either way the
/// athlete continues into the app, never blocked. Driven via the `--onboarding-review` deep link,
/// which raises the beat over a settled onboarding step.
final class OnboardingReviewUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testRatingBeatAppearsAndContinuesIntoApp() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--onboarding", "--onboarding-review"]
        // The Today map (rendered behind onboarding) asks for location — dismiss any system alert.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()   // clear any permission alert via the interruption monitor

        // The rating beat is up: its copy and both controls are present.
        let rate = app.buttons["Rate momentum"]
        XCTAssertTrue(rate.waitForExistence(timeout: 15),
                      "The end-of-onboarding rating beat ('Rate momentum') never appeared.")
        XCTAssertTrue(app.staticTexts["Enjoying momentum?"].exists,
                      "The rating beat should show its priming headline.")
        XCTAssertTrue(app.buttons["Maybe later"].exists,
                      "The rating beat must offer a 'Maybe later' skip so it never blocks entry.")

        // Tapping the primary CTA continues into the app (the native prompt is system-owned and
        // rate-limited; the flow must proceed regardless of whether it shows).
        rate.tap()
        app.tap()   // dismiss the Today map's location prompt if it surfaces on entry
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 10),
                      "Completing the rating beat should land in the app with the tab bar visible.")
    }
}
