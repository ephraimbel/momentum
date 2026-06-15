import XCTest

/// Opens Progress → Trends and verifies the weekly load/distance charts render with seeded data.
final class ProgressChartsUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWeeklyChartsShowValues() {
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
        app.tap()   // clear any permission alert via the interruption monitor

        // Switch to the Progress tab.
        let progressTab = app.tabBars.buttons["Progress"]
        XCTAssertTrue(progressTab.waitForExistence(timeout: 15), "Progress tab not found.")
        progressTab.tap()

        // The weekly charts should render (Trends is the default segment).
        XCTAssertTrue(app.staticTexts["Weekly training load"].waitForExistence(timeout: 10),
                      "Weekly training load chart not found.")
        XCTAssertTrue(app.staticTexts["Weekly distance"].waitForExistence(timeout: 5),
                      "Weekly distance chart not found.")
    }
}
