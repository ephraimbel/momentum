import XCTest

/// The onboarding hard gate (user call 2026-07-10): after the plan reveal, every new athlete meets
/// the paywall — no close button, no swipe-away — and the only ways forward are trial/subscribe/
/// restore. Verifies the full moment end-to-end: reveal → hard paywall → trial CTA → the flow
/// continues into notifications. Uses the local purchase seam (no RevenueCat in DEBUG), so the
/// trial tap genuinely exercises the grant → dismiss → advance path.
final class OnboardingPaywallUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testHardPaywallGatesTheRevealAndTrialUnlocks() {
        let app = XCUIApplication()
        // Seeded profile (reveal needs one) + forced-free entitlement so the gate actually shows.
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

        // The paywall appears — and it is HARD: no close affordance anywhere.
        let trialCTA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(trialCTA.waitForExistence(timeout: 10), "Hard paywall didn't appear after the reveal.")
        XCTAssertFalse(app.buttons["Close"].exists, "The onboarding paywall must not offer a close button.")

        // Starting the trial (local seam grants entitlement) dismisses the gate and the flow
        // continues exactly where it should: the notifications step.
        trialCTA.tap()
        XCTAssertTrue(app.buttons["Turn on reminders"].waitForExistence(timeout: 10),
                      "Subscribing didn't advance onboarding to the notifications step.")
    }
}
