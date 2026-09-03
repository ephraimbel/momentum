import XCTest

/// Adds a tune-up race from Plan settings the way an athlete would (2026-09-03): open the section,
/// add one with the editor's defaults, see it listed, rebuild, and find the week bent around it on
/// the Plan page's context line.
final class PlanSettingsTuneUpUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // The committed 5-day athlete with a half marathon ~7 weeks out: room for a tune-up.
        app.launchArguments = ["--reset-store", "--seed-demo", "--seed-plan-5day", "--plan-tab", "--plan-settings"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        // No `app.tap()` here: the screen's centre is a goal card on this sheet, and tapping it
        // would switch the athlete off racing before the test looks for the tune-up section.
        return app
    }

    private func scroll(to element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) {
        var tries = 0
        while (!element.exists || !element.isHittable) && tries < attempts {
            app.swipeUp()
            tries += 1
        }
    }

    func testAddATuneUpRebuildAndSeeItOnThePlan() {
        let app = launch()
        let add = app.buttons["add-tuneup"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "Plan settings should open with the tune-up section.")
        scroll(to: add, in: app)
        add.tap()

        // The editor: defaults are a 10K, four weeks out, raced. Add it as it is.
        let save = app.buttons["tuneup-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "The tune-up editor should open.")
        XCTAssertTrue(app.staticTexts["Race it"].waitForExistence(timeout: 5))
        save.tap()

        // Listed, and the structural rebuild is armed.
        let row = app.buttons["tuneup-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The tune-up should be listed after adding it.")
        XCTAssertTrue(row.label.contains("10K") && row.label.contains("Race it"), "row: \(row.label)")
        let rebuild = app.buttons["Rebuild plan"]
        XCTAssertTrue(rebuild.waitForExistence(timeout: 5), "Adding a tune-up is a structural change.")
        rebuild.tap()

        // Back on the Plan page: the next start line is the tune-up, the goal behind it.
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Tune-up 10K'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 15), "The plan's context line should lead with the tune-up.")
    }
}
