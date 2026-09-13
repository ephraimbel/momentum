import XCTest

/// Location is asked on its own beat after the review (owner call 2026-09-12), never before the
/// plan: the athlete reaches Today with the grant already made, so the map opens on them and
/// Start raises nothing.
final class OnboardingLocationHandoffUITests: XCTestCase {
    func testLocationIsRequestedOnItsBeatAfterTheReview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.resetAuthorizationStatus(for: .location)
        app.resetAuthorizationStatus(for: .health)
        // Entitled, so the last beat enters Today instead of checkout.
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-reveal", "--review-no-ask", "--debug-pro"]
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

        // Health first, with no location alert anywhere near it.
        XCTAssertTrue(app.staticTexts["Train around your recovery"].waitForExistence(timeout: 15))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        crossHealthBeat(app)

        // Then location: its Continue is what raises the system alert.
        XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 15))
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "No location alert before the athlete taps")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "location-beat"; before.lifetime = .keepAlways
        add(before)
        app.buttons["Continue"].firstMatch.tap()
        let allow = springboard.buttons["Allow While Using App"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "The location beat must request the grant")
        allow.tap()

        // Into the app with the grant made: Today, and Start asks for nothing more.
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        let start = app.buttons["todayDeckStart"]
        if start.waitForExistence(timeout: 10), start.isHittable {
            start.tap()
            XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3),
                           "Start must not ask again for a grant made during setup")
        }
    }
}
