import XCTest

/// Location is asked on its own beat after the review (owner call 2026-09-12), never before the
/// plan: the athlete reaches Today with the grant already made, so the map opens on them and
/// Start raises nothing.
final class OnboardingLocationHandoffUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // Resetting system consent while the previous app is still alive can deliver its
        // pending authorization callback into the next test's permission sequence.
        XCUIApplication().terminate()
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

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
        let healthApp = XCUIApplication(bundleIdentifier: "com.apple.HealthPrivacyService")
        XCTAssertTrue(healthApp.buttons["Allow"].waitForExistence(timeout: 10),
                      "Fresh Health permission must open the actual system sheet without a Continue tap")
        let healthShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        healthShot.name = "health-system-permission"; healthShot.lifetime = .keepAlways
        add(healthShot)
        crossHealthBeat(app)

        // Then location: the page raises the system alert ITSELF on arrival (owner call
        // 2026-09-13), so the grant is asked for every time without a tap; Continue stays as
        // the fallback for a device that already answered.
        XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 15))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "location-beat"; before.lifetime = .keepAlways
        add(before)
        let allow = springboard.buttons["Allow While Using App"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "The location beat must request the grant on arrival")
        let locationShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        locationShot.name = "location-system-permission"; locationShot.lifetime = .keepAlways
        add(locationShot)
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

    func testDeclinedLocationOffersSettingsAndCanContinue() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-primers", "--debug-pro"]
        app.launch()
        let deny = springboard.buttons.matching(NSPredicate(
            format: "label == %@ OR label == %@", "Don't Allow", "Don’t Allow")).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 15))
        deny.tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))

        // An app-data reset cannot reset Apple's consent choice. Returning to this beat must
        // explain the saved denial and provide a working Settings route, not a dead Continue.
        app.terminate()
        app.launch()
        let settings = app.buttons["onboarding.location.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        settings.tap()
        let settingsApp = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settingsApp.wait(for: .runningForeground, timeout: 10))
        app.activate()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        app.buttons["Continue"].firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))
    }

    func testHealthSheetSurvivesBackgroundAndDoesNotRepeatAfterAnswer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let healthApp = XCUIApplication(bundleIdentifier: "com.apple.HealthPrivacyService")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.resetAuthorizationStatus(for: .health)
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-health", "--debug-pro"]
        app.launch()
        XCTAssertTrue(healthApp.buttons["Allow"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(healthApp.buttons["Allow"].waitForExistence(timeout: 15))
        crossHealthBeat(app)
        let allow = springboard.buttons["Allow While Using App"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        allow.tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["You've already made your Health sharing choices on this device. You can change them in the Health app."].waitForExistence(timeout: 15))
        XCTAssertNotEqual(healthApp.state, .runningForeground)
        app.buttons["Continue"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 15))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        app.buttons["Continue"].firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))
    }

    func testDecliningBothPermissionsOpensCheckoutInBothMotionModes() {
        let app = XCUIApplication()
        let healthApp = XCUIApplication(bundleIdentifier: "com.apple.HealthPrivacyService")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denial = NSPredicate(format: "label == %@ OR label == %@", "Don't Allow", "Don’t Allow")
        for reduced in [false, true] {
            app.terminate()
            app.resetAuthorizationStatus(for: .health)
            app.resetAuthorizationStatus(for: .location)
            app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding",
                                   "--onboarding-health", "--debug-free"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            let healthDeny = healthApp.buttons.matching(denial).firstMatch
            XCTAssertTrue(healthDeny.waitForExistence(timeout: 15))
            XCTAssertFalse(springboard.alerts.firstMatch.exists)
            healthDeny.tap()
            // iOS confirms an all-off choice before completing Health authorization.
            // The confirmation is hosted in Momentum's window. Targeting the Health service
            // instead makes XCTest treat it as an interruption and dismiss it before the tap.
            let healthConfirmation = app.alerts["Health Access"].buttons["OK"]
            XCTAssertTrue(healthConfirmation.waitForExistence(timeout: 10))
            healthConfirmation.tap()
            XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 15))
            let locationDeny = springboard.buttons.matching(denial).firstMatch
            XCTAssertTrue(locationDeny.waitForExistence(timeout: 15))
            locationDeny.tap()
            // The system alert must hand off to a live checkout, not leave a primer or spinner.
            XCTAssertTrue(app.staticTexts["YOUR GOAL"].waitForExistence(timeout: 15))
            let restore = app.buttons["Restore"]
            XCTAssertTrue(restore.exists && restore.isHittable)
            XCTAssertFalse(springboard.alerts.firstMatch.exists)
            XCTAssertNotEqual(healthApp.state, .runningForeground)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = reduced ? "permission-denial-checkout-reduced-motion" : "permission-denial-checkout-motion"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }
}
