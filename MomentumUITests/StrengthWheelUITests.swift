import XCTest

/// The Trends strength chapter (2026-08-28): the muscle-load wheel flips metric on its chevron,
/// and a progression row opens the lift's full history.
final class StrengthWheelUITests: XCTestCase {
    func testWheelTogglesAndRowOpensTheLift() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--progress-tab", "--progress-scroll-strength"]
        app.launch()
        let title = app.staticTexts["Total volume"]
        XCTAssertTrue(title.waitForExistence(timeout: 12), "the wheel card should be on screen")
        app.buttons["Switch to Muscular load"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Muscular load"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Chest"].exists && app.staticTexts["Legs"].exists)
        // A progression row opens the lift's history.
        let row = app.staticTexts["Barbell Row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "the lift detail sheet should open")
        app.buttons["Done"].tap()
        // And the arrow opens every lift.
        app.buttons["All lifts"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Strength progression"].waitForExistence(timeout: 5))
    }
}
