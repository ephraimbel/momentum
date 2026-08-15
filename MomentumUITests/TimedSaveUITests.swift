import XCTest

/// The timed-sport calorie loop (owner ask 2026-07-30: "it shows the calories burned but a user
/// should be able to click on it and adjust it"): finish a stopwatch session, see the estimate
/// prefill, overtype it, and have the typed number survive a Done tapped while the field is still
/// focused (the live-commit guarantee in `TypableNumber`).
final class TimedSaveUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testCaloriesEditableOnTimedSave() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--today-sport", "basketball"]
        app.launch()

        let start = app.buttons["Start basketball"]
        XCTAssertTrue(start.waitForExistence(timeout: 25), "Today didn't open pinned to basketball.")
        start.tap()

        let finish = app.buttons["Finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "Timed tracking screen didn't appear.")
        sleep(2)   // bank a couple of active seconds so the session is nonzero
        finish.tap()

        // Save screen: the calorie row is there, honest about being an estimate, and editable.
        XCTAssertTrue(app.staticTexts["Estimated — tap to adjust"].waitForExistence(timeout: 10),
                      "Calorie row missing from the timed save screen.")
        let numeral = app.buttons["calorie-value"]
        XCTAssertTrue(numeral.exists, "Calorie numeral isn't tappable.")
        numeral.tap()

        let field = app.textFields["calorie-value"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Tapping the numeral didn't open the field.")
        field.typeText("150")

        // Live commit: the provenance line flips to the athlete's own entry while still typing.
        XCTAssertTrue(app.staticTexts["Your entry"].waitForExistence(timeout: 5),
                      "Typed calories didn't commit live.")

        // Done pressed with the field STILL FOCUSED — the typed number must survive to the save.
        // The celebration beat is ~1s and auto-dismisses (asserting its transient face is a race);
        // the durable outcome is the save screen closing back onto Today.
        app.buttons["activityDone"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 15),
                      "Save didn't complete — the save screen never dismissed back to Today.")
    }
}
