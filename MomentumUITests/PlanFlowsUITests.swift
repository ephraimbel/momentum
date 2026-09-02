import XCTest

/// The plan lifecycle flows (2026-07-12): goals change, so the Plan page offers two first-class
/// intents — adjust the current plan, or start a completely new one. This drives the new-plan flow
/// live: fresh form, blank name, "Create plan" commits a full rebuild and lands back on the page.
final class PlanFlowsUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func testStartANewPlanFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--plan-tab", "--plan-new"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()

        // The creation frame: its own title and a blank name, but no silently inherited objective.
        XCTAssertTrue(app.navigationBars["New plan"].waitForExistence(timeout: 15),
                      "Start-a-new-plan should open its own framed sheet.")
        let create = app.buttons["Create plan"]
        XCTAssertTrue(create.exists, "The new-plan flow must always offer Create plan.")
        XCTAssertEqual(create.value as? String, "Choose a goal",
                       "A new plan must wait for an explicit goal choice.")
        let nameField = app.textFields["e.g. Austin Marathon"]
        XCTAssertTrue(nameField.exists,
                      "A new plan starts with a blank name — its own occasion.")
        let goalHeader = app.staticTexts["YOUR GOAL"]
        XCTAssertTrue(goalHeader.exists)
        XCTAssertLessThan(nameField.frame.minY, goalHeader.frame.minY,
                          "Plan name belongs at the top of both plan forms.")

        // A race is not a complete goal until its distance is explicit; switching to a complete
        // open-ended goal arms creation immediately.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run a race'"))
            .firstMatch.tap()
        XCTAssertEqual(create.value as? String, "Choose a race distance",
                       "A race plan must wait for a race distance.")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run farther & faster'"))
            .firstMatch.tap()
        XCTAssertEqual(create.value as? String, "Ready to create",
                       "Choosing a complete goal should arm plan creation.")
        create.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH 'Run farther & faster · Week 1 of'"
        )).firstMatch.waitForExistence(timeout: 10)
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Week 1'")).firstMatch.waitForExistence(timeout: 10),
                      "Creating should land back on the Plan page with a fresh week one.")
    }

    @MainActor
    func testAdjustPlanKeepsExistingNameAboveGoal() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store", "--seed-demo", "--seed-plan-name", "--plan-tab", "--plan-settings",
        ]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        XCTAssertTrue(app.navigationBars["Plan settings"].waitForExistence(timeout: 15),
                      "Adjusting should open the existing-plan form.")
        let nameField = app.textFields["e.g. Austin Marathon"]
        let goalHeader = app.staticTexts["YOUR GOAL"]
        XCTAssertTrue(nameField.exists, "Adjusting must keep the editable plan name visible.")
        XCTAssertFalse((nameField.value as? String ?? "").isEmpty,
                       "Adjusting must prefill the athlete's existing plan name.")
        XCTAssertTrue(goalHeader.exists)
        XCTAssertLessThan(nameField.frame.minY, goalHeader.frame.minY,
                          "Plan name must remain above goal when adjusting an existing plan.")
    }
}
