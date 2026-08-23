import XCTest

/// Opening a custom-scheme URL from outside the app raises a SpringBoard confirmation —
/// **Open in "momentum"?** — and the app does not receive the URL until it is answered.
///
/// This is why the auth E2E tests appeared to be "waiting on an orchestrator that never fired".
/// The orchestrator fired correctly every time: `simctl openurl` delivered
/// `momentum://auth-callback#…&type=recovery`, iOS parked it behind that dialog, nothing tapped
/// Open, and `handleAuthCallback` was never called at all. Confirmed by streaming the app's own
/// `auth` breadcrumbs while firing a link — not one line was logged, and a screenshot showed the
/// dialog sitting over the welcome.
///
/// Worth knowing beyond the tests: a real athlete tapping a recovery link sees this same prompt.
extension XCTestCase {

    /// Wait for `element`, answering the deep-link confirmation if iOS raises one.
    ///
    /// `addUIInterruptionMonitor` is not reliable here — it only runs when the test next interacts
    /// with the app, and this test's next action IS the wait. So poll both: whichever appears
    /// first wins, and the dialog is dismissed the moment it shows.
    @discardableResult
    func waitForDeepLink(_ element: XCUIElement, timeout: TimeInterval = 90) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return true }
            // "Open" on the confirmation; some iOS versions title it differently, so match either.
            for label in ["Open", "Open in “momentum”?"] {
                let button = springboard.buttons[label]
                if button.exists && button.isHittable { button.tap(); break }
            }
            usleep(300_000)
        }
        return element.exists
    }
}
