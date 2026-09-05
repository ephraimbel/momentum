import XCTest

/// Motion may acknowledge a choice, but must never swallow it, delay Continue, or hide a row.
final class OnboardingMotionUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func testChoicesAndBackNavigationWorkWithAndWithoutMotion() {
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-goal"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            XCTAssertTrue(app.staticTexts["What are we training for?"].waitForExistence(timeout: 20))
            let goal = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Stay consistent'")).firstMatch
            XCTAssertTrue(goal.waitForExistence(timeout: 5))
            XCTAssertTrue(goal.isHittable)
            goal.tap()
            XCTAssertTrue(goal.isSelected)
            let alternative = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Become a stronger runner'")).firstMatch
            alternative.tap()
            XCTAssertTrue(alternative.isSelected)
            XCTAssertFalse(goal.isSelected)
            goal.tap()
            XCTAssertTrue(goal.isSelected)
            XCTAssertLessThanOrEqual(alternative.frame.maxY, app.buttons["Continue"].frame.minY)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = reduced ? "onboarding-choice-reduced-motion" : "onboarding-choice-motion"
            shot.lifetime = .keepAlways
            add(shot)

            app.buttons["Continue"].doubleTap()
            XCTAssertTrue(app.staticTexts["What supports your running?"].waitForExistence(timeout: 5))
            app.buttons["Back"].doubleTap()
            XCTAssertTrue(app.staticTexts["What are we training for?"].waitForExistence(timeout: 5))
            XCTAssertTrue(goal.isSelected, "The choice must survive the return transition.")
            XCTAssertTrue(app.buttons["Continue"].isEnabled)
            app.terminate()
        }
    }
    @MainActor
    func testInjurySelectionDoesNotMoveTheControls() {
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-injuries"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            let knee = app.buttons["Knee"]
            let clear = app.buttons["No injuries, I'm all clear"]
            XCTAssertTrue(knee.waitForExistence(timeout: 15))
            XCTAssertTrue(clear.isHittable)
            let originalKnee = knee.frame
            let originalClear = clear.frame
            knee.tap()
            XCTAssertTrue(knee.isSelected)
            XCTAssertEqual(knee.frame.minY, originalKnee.minY, accuracy: 1)
            XCTAssertEqual(clear.frame.minY, originalClear.minY, accuracy: 1)
            app.buttons["Ankle"].tap()
            XCTAssertTrue(knee.isSelected)
            knee.tap()
            app.buttons["Ankle"].tap()
            XCTAssertFalse(knee.isSelected)
            XCTAssertEqual(clear.frame.minY, originalClear.minY, accuracy: 1)
            XCTAssertLessThanOrEqual(clear.frame.maxY, app.buttons["Continue"].frame.minY)
            capture(app, name: reduced ? "injuries-still" : "injuries-motion")
            clear.tap()
            XCTAssertTrue(app.staticTexts["A few personal details."].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testReminderPreviewAndLocationHandoffInBothMotionModes() {
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-notifications"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            XCTAssertTrue(app.staticTexts["A nudge before each run"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["Turn on reminders"].isHittable)
            capture(app, name: reduced ? "reminder-still" : "reminder-motion")
            app.buttons["Maybe later"].doubleTap()
            XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Continue"].isHittable)
            XCTAssertFalse(app.buttons["Maybe later"].exists)
            capture(app, name: reduced ? "route-still" : "route-motion")
            app.terminate()
        }
    }

    @MainActor
    func testGeneratedPlanArrivesAfterBackgroundingInBothMotionModes() {
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-building"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            XCUIDevice.shared.press(.home)
            app.activate()
            let cta = app.buttons["onboarding.reveal.continue"]
            XCTAssertTrue(cta.waitForExistence(timeout: 25))
            XCTAssertTrue(cta.isHittable)
            XCTAssertTrue(app.staticTexts["YOUR FIRST WEEK"].exists)
            XCTAssertFalse(app.staticTexts["Building your plan"].exists)
            capture(app, name: reduced ? "generated-plan-still" : "generated-plan-motion")
            app.terminate()
        }
    }

    @MainActor
    func testReducedMotionWelcomeStillOffersBothDoors() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--reset-auth", "--ui-test-reduce-motion"]
        app.launch()
        let returning = app.buttons["I already have an account"]
        XCTAssertTrue(returning.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Build my plan"].isHittable)
        capture(app, name: "welcome-still")
        returning.tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertTrue(returning.waitForExistence(timeout: 5))
        app.buttons["Build my plan"].tap()
        XCTAssertTrue(app.staticTexts["Let's make it yours."].waitForExistence(timeout: 10))
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
