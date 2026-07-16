import XCTest

/// The onboarding paywall (freemium, 2026-07-14): after the plan reveal every new athlete meets the
/// paywall, but it's SOFT — subscribe/trial to unlock the coach + full plan, or close it and continue
/// into the app on the free tier. Verifies BOTH paths: close-to-free-tier, and trial-grants-and-advances.
/// Uses the local purchase seam (no RevenueCat in DEBUG), so the trial tap genuinely exercises the
/// grant → dismiss → advance path.
final class OnboardingPaywallUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launchToPaywall(_ app: XCUIApplication) {
        // Seeded profile (reveal needs one) + forced-free entitlement so the paywall actually shows.
        app.launchArguments = ["--seed-demo", "--debug-free", "--onboarding", "--onboarding-reveal"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // The reveal's CTA hands off to the paywall.
        let revealCTA = app.buttons["This looks great"]
        XCTAssertTrue(revealCTA.waitForExistence(timeout: 15), "Plan reveal didn't show its CTA.")
        revealCTA.tap()
    }

    /// SOFT: the paywall offers a close affordance, and closing it drops the athlete into the app on
    /// the free tier — the flow continues to the notifications step.
    func testSoftPaywallClosesIntoTheFreeTier() {
        let app = XCUIApplication()
        launchToPaywall(app)

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10),
                      "The onboarding paywall must offer a close button (soft/freemium).")
        close.tap()
        XCTAssertTrue(app.buttons["Turn on reminders"].waitForExistence(timeout: 10),
                      "Closing the soft paywall didn't continue onboarding into the free tier (notifications step).")
    }

    /// The trial CTA still grants entitlement and advances — the paid path is unchanged.
    func testTrialUnlocksAndAdvances() {
        let app = XCUIApplication()
        launchToPaywall(app)

        let trialCTA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(trialCTA.waitForExistence(timeout: 10), "Paywall didn't appear after the reveal.")
        trialCTA.tap()
        XCTAssertTrue(app.buttons["Turn on reminders"].waitForExistence(timeout: 10),
                      "Subscribing didn't advance onboarding to the notifications step.")
    }
}
