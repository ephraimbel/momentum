import XCTest

/// The plan lifecycle flows (2026-07-12): goals change, so the Plan page offers two first-class
/// intents — adjust the current plan, or start a completely new one. This drives the new-plan flow
/// live: fresh form, blank name, "Create plan" commits a full rebuild and lands back on the page.
final class PlanFlowsUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testStartANewPlanFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--plan-tab", "--plan-new"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // The creation frame: its own title, a blank name field, and an always-armed Create CTA.
        XCTAssertTrue(app.navigationBars["New plan"].waitForExistence(timeout: 15),
                      "Start-a-new-plan should open its own framed sheet.")
        let create = app.buttons["Create plan"]
        XCTAssertTrue(create.exists, "The new-plan flow must always offer Create plan.")
        XCTAssertTrue(app.textFields["e.g. Austin Marathon"].exists,
                      "A new plan starts with a blank name — its own occasion.")

        // Creating commits a full rebuild and returns to the Plan page.
        create.tap()
        XCTAssertTrue(app.staticTexts["Training plan · Week 1 of 5"].waitForExistence(timeout: 10)
                      || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Training plan'")).firstMatch.waitForExistence(timeout: 10)
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Week 1'")).firstMatch.waitForExistence(timeout: 10),
                      "Creating should land back on the Plan page with a fresh week one.")
    }
}
