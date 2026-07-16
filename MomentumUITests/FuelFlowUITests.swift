import XCTest

/// The FUEL loop, end to end on the tab: log a meal by sentence → the estimate path resolves
/// (offline/undeployed → the graceful "set the numbers" fallback) → manual numbers via the edit
/// sheet → the day's readout rolls to the new total. Screenshots at each beat.
final class FuelFlowUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testLogEditAndReadoutLoop() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--fuel", "--reset-fuel"]
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
        // The entry reveal-cascade can swallow the first tap's focus — retap until the keyboard
        // confirms it (typeText without focus hard-fails the run).
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        }
        field.typeText("big pasta dinner with chicken")
        shot(app, "1a-composer-glow")   // the iridescent ring while writing (coach-composer match)
        app.buttons["Log meal"].tap()

        // The row lands instantly (offline-first), then the estimate resolves — to REAL numbers when
        // the deployed function is reachable, or to the honest set-it-yourself fallback when not.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "big pasta dinner")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Logged meal row didn't appear.")
        let fallback = app.staticTexts["Couldn't estimate — tap to set the numbers"]
        // The ROW's numbers line ("≈54 g carbs · 620 kcal · …") — the "g carbs ·" separator is what
        // distinguishes it from the readout strip's "≈0 of 350 g carbs" line. Matching anything
        // looser resolves this wait instantly and taps the row while it's still estimating
        // (estimating rows deliberately don't open the sheet).
        let numbers = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "≈", "g carbs ·")).firstMatch
        let resolved = NSPredicate { _, _ in fallback.exists || numbers.exists }
        let wait = XCTNSPredicateExpectation(predicate: resolved, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 25), .completed,
                       "Pending estimate never resolved (neither numbers nor fallback).")
        shot(app, "2-meal-logged-resolved")

        // Set the numbers by hand — carbs first field in the edit sheet. A live estimate opens the
        // sheet in ITEMS mode (portion steppers); "Set totals by hand" swaps to the direct fields.
        // An offline/fallback meal has no items and opens on the fields directly — handle both.
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit meal"].waitForExistence(timeout: 8), "Edit sheet didn't open.")
        let switchToTotals = app.buttons["Set totals by hand"]
        if switchToTotals.waitForExistence(timeout: 3) {
            shot(app, "3a-items-portions")   // per-item rows + qty steppers (the Amy beat)
            switchToTotals.tap()
        }
        let carbsField = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "—")).element(boundBy: 0)
        XCTAssertTrue(carbsField.waitForExistence(timeout: 5), "Carbs field not found.")
        // A live estimate may have pre-filled the field; double-tap selects the existing number so
        // typing REPLACES it (tap+delete is cursor-position roulette in XCUITest).
        carbsField.doubleTap()
        carbsField.typeText("150")
        shot(app, "3-edit-sheet")
        app.buttons["Save"].tap()

        // The readout strip rolls to the manual total ("Building · ≈150 of 350 g carbs").
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "≈150 of"))
            .firstMatch.waitForExistence(timeout: 8),
                      "Readout strip didn't update to the manual entry.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "≈150 g carbs"))
            .firstMatch.waitForExistence(timeout: 5), "Meal row numbers line didn't update.")
        shot(app, "4-readout-updated")

        // History: the top-right calendar opens the day-by-day journal with today's meal in it.
        app.buttons["Meal history"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 6), "History page didn't open.")
        XCTAssertTrue(app.staticTexts["TODAY"].waitForExistence(timeout: 4), "Today's section missing in history.")
        shot(app, "5-history")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
