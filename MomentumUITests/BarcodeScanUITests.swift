import XCTest

/// The barcode lane, end to end in `--barcode-demo` (the sim has no camera, so the scanner
/// self-presents with a canned product): confirm the card, log two servings, find the meal in
/// the journal with label-doubled numbers, and confirm the composer's scan button is there for
/// the real-camera path.
final class BarcodeScanUITests: XCTestCase {

    func testScanConfirmAndLog() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--debug-pro", "--fuel", "--barcode-demo"]
        app.launch()

        // The demo product card lands without a camera (scanner self-presents on Fuel).
        XCTAssertTrue(app.staticTexts["Crunchy Peanut Butter Granola Bars"].waitForExistence(timeout: 12),
                      "Demo product card did not appear.")
        XCTAssertTrue(app.staticTexts["190"].exists, "Per-serving calories missing.")

        // Two servings → the numbers double live.
        app.buttons["More servings"].firstMatch.tap()
        app.buttons["More servings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["380"].waitForExistence(timeout: 3),
                      "Servings stepper did not scale the calories.")

        app.buttons["Log it"].firstMatch.tap()

        // Back on Fuel with the meal in the journal, reading like the athlete wrote it.
        // The row is a button whose AX label is "Meal: <the athlete's words>".
        XCTAssertTrue(app.buttons["Meal: 2 x Nature Valley Crunchy Peanut Butter Granola Bars"]
            .waitForExistence(timeout: 8), "Scanned meal missing from the journal.")

        // The composer's entry point for the real-camera path.
        XCTAssertTrue(app.buttons["Scan a barcode"].firstMatch.waitForExistence(timeout: 5),
                      "Scan button missing from the composer.")
    }
}
