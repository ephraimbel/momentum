import XCTest

/// Real scene lifecycle, not `simctl launch` of a competing app. The corresponding analytics log
/// / local queue is inspected after this run for two background ends and two distinct session IDs.
final class ScreenTrackingLifecycleUITests: XCTestCase {
    @MainActor
    func testHomeAndReturnOnTheSameScreen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        // Wait for the actual tab, rather than backgrounding during splash/onboarding setup.
        XCTAssertTrue(app.buttons["Plan"].waitForExistence(timeout: 20))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Before Home — actual foreground screen"
        before.lifetime = .keepAlways
        add(before)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.buttons["Plan"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    }
}
