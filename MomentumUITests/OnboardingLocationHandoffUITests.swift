import XCTest

/// Location belongs to a recording action. A fresh athlete can reach Today without granting it.
final class OnboardingLocationHandoffUITests: XCTestCase {
    func testLocationIsRequestedAtStartInsteadOfOnboarding() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-reveal", "--review-no-ask"]
        app.launch()
        let reveal = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        reveal.tap()
        let review = app.buttons["onboarding.review.continue"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.isHittable)
        review.tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        app.terminate()
        app.launchArguments = ["--reset-store", "--seed-empty", "--debug-pro", "--today-sport", "run"]
        app.launch()
        let start = app.buttons["todayDeckStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        // Keep billing hermetic without --ui-test-route, which deliberately bypasses GPS consent.
        XCTAssertTrue(start.waitForExistence(timeout: 5) && start.isHittable)
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "today-before-location-request"; before.lifetime = .keepAlways
        add(before)
        start.tap()
        let allow = springboard.buttons["Allow While Using App"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "Start must request recording permission")
        allow.tap()
    }
}
