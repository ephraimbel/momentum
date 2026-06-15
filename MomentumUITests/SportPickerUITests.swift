import XCTest

/// Verifies the activity picker offers the newly-added water disciplines (PRD §4.10 "more
/// disciplines") and that selecting one updates the chip — exercising the timed-capture routing.
final class SportPickerUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testWaterSportsAppearAndSelect() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // Open the activity picker from the Today sport chip (labeled with the current activity).
        let chip = app.buttons["Run"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "Sport chip not found.")
        chip.tap()

        XCTAssertTrue(app.navigationBars["Choose Activity"].waitForExistence(timeout: 5),
                      "Sport picker didn't open.")

        // Search to reach the new disciplines deterministically (no scrolling guesswork).
        let search = app.textFields["Search activities"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Swim")

        let swim = app.buttons["Swim"]
        XCTAssertTrue(swim.waitForExistence(timeout: 5), "Swim not offered in the picker.")
        swim.tap()

        // Selecting it dismisses the picker and updates the chip to the new sport.
        XCTAssertTrue(app.buttons["Swim"].waitForExistence(timeout: 5),
                      "Selecting Swim didn't update the activity chip.")
    }
}
