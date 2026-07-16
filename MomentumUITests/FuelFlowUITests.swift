import XCTest

/// The FUEL loop, end to end on the tab: log a meal by sentence → the estimate path resolves
/// (offline/undeployed → the graceful "set the numbers" fallback) → manual numbers via the edit
/// sheet → the day's readout rolls to the new total. Screenshots at each beat.
final class FuelFlowUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testLogEditAndReadoutLoop() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--fuel"]
        app.launch()

        // The deep link lands on the Fuel tab.
        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 20), "Fuel page didn't appear.")
        XCTAssertTrue(app.tabBars.buttons["Fuel"].exists, "Fuel tab missing from the bar.")
        shot(app, "1-fuel-empty")

        // Log a meal by sentence. (The composer is a vertical-axis TextField — match by placeholder
        // across element types so the query survives how XCUITest surfaces it.)
        let byPlaceholder = NSPredicate(format: "placeholderValue BEGINSWITH %@", "What did you eat?")
        let field = app.descendants(matching: .any).matching(byPlaceholder).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Composer field not found.")
        field.tap()
        field.typeText("big pasta dinner with chicken")
        app.buttons["Log meal"].tap()

        // The row lands instantly (offline-first), then the estimate resolves — in the test rig the
        // function isn't reachable, so the honest fallback must appear.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "big pasta dinner")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Logged meal row didn't appear.")
        let fallback = app.staticTexts["Couldn't estimate — tap to set the numbers"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 20), "Pending estimate never resolved to the manual fallback.")
        shot(app, "2-meal-logged-fallback")

        // Set the numbers by hand — carbs first field in the edit sheet.
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit meal"].waitForExistence(timeout: 8), "Edit sheet didn't open.")
        let carbsField = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "—")).element(boundBy: 0)
        XCTAssertTrue(carbsField.waitForExistence(timeout: 5), "Carbs field not found.")
        carbsField.tap()
        carbsField.typeText("150")
        shot(app, "3-edit-sheet")
        app.buttons["Save"].tap()

        // The readout rolls to the manual total.
        XCTAssertTrue(app.staticTexts["≈150 g"].waitForExistence(timeout: 8),
                      "Header carb total didn't update to the manual entry.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "≈150 g carbs"))
            .firstMatch.waitForExistence(timeout: 5), "Meal row numbers line didn't update.")
        shot(app, "4-readout-updated")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
