import XCTest

/// Only run the reset-based fixtures on an isolated QA installation, never an athlete's store.
@MainActor
final class ResponsivenessUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // Rating prompts have their own suite; don't let an unrelated engagement milestone
        // interrupt these deterministic logging/navigation fixtures.
        app.launchArguments = ["--seed-demo", "--debug-pro", "--awards-quiet",
                               "-com.momentum.review.rated.v2", "YES"] + args
        app.launch()
        ScrollTestSupport.dismissRecoveryIfPresent(app, timeout: 2)
        return app
    }

    private func globeRoundTrips(_ args: [String]) {
        // Open controls by tapping, not a launch flag that reopens them on every onAppear.
        let app = launch(args)
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))
        for iteration in 0..<4 {
            let globe = app.buttons["See the world"]
            if !globe.exists || !globe.isHittable { app.buttons["More"].tap() }
            XCTAssertTrue(globe.waitForExistence(timeout: 5))
            globe.tap()
            let back = app.buttons["Back to Today"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            if iteration == 0 {
                let ready = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "Globe ready"), object: back)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
                shot(app, "world-ready")
            }
            // No flight-duration sleeps: return as soon as the control is usable.
            back.tap()
            XCTAssertTrue(back.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.buttons["More"].isHittable)
        }
        app.tabBars.buttons["Plan"].tap()
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["More"].isHittable)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        shot(app, "globe-round-trips-settled")
    }

    func testGlobeRepeatedRoundTrips() {
        globeRoundTrips(["--today-sport", "run", "-com.momentum.mapStyle", "standard"])
    }

    func testGlobeFromStrengthFirstMount() {
        globeRoundTrips(["--today-sport", "strength"])
    }

    func testGlobeWithReduceMotion() {
        globeRoundTrips(["--today-sport", "run", "--ui-test-reduce-motion"])
    }

    func testLongPlanWeekSelectionAndTabReturn() {
        let app = launch(["--reset-store", "--seed-plan-long", "--plan-tab"])
        let first = app.buttons["planWeek.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 25))
        for index in [2, 0, 4, 1, 3, 0] {
            let week = app.buttons["planWeek.\(index)"]
            XCTAssertTrue(week.isHittable)
            week.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: week)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
        }
        app.tabBars.buttons["Today"].tap()
        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.isSelected)
        shot(app, "plan-long-block-return")
    }

    func testLocalMealRepeatPreservesDraftAndSurvivesRelaunch() {
        let app = launch(["--reset-store", "--reset-fuel", "--fuel-tab", "--ui-test-reduce-motion"])
        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 20))
        let field = app.descendants(matching: .any)["fuel-composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        field.typeText("banana")
        app.buttons["Log meal"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "label == %@", "Meal: banana"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(app.staticTexts["Estimating…"].exists, "A staple must resolve locally.")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        field.typeText("unsent tea")
        // The quick repeat must not consume a separate draft, even if we dismiss the keyboard.
        app.swipeUp()
        let repeatMeal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Log again:")).firstMatch
        XCTAssertTrue(repeatMeal.waitForExistence(timeout: 5))
        repeatMeal.tap()
        XCTAssertEqual(field.value as? String, "unsent tea")
        XCTAssertEqual(rows.count, 2)
        shot(app, "fuel-local-repeat-with-draft")
        app.terminate()
        app.launchArguments = ["--seed-demo", "--debug-pro", "--awards-quiet", "--fuel-tab"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 15))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2, "Both local logs must be saved before navigation or termination.")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
