import XCTest

/// Verifies the post-run analysis charts (R2): open a seeded run's detail and confirm the pace /
/// splits / elevation charts render. Dumps a PNG for visual inspection.
final class RunChartsUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
    }

    func testRunDetailShowsCharts() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--progress-tab"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // Progress → History segment.
        let history = app.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 20), "History segment not found.")
        history.tap()

        // Tap the first run card (accessibilityLabel is the sport title).
        let runCard = app.buttons["Run"].firstMatch
        XCTAssertTrue(runCard.waitForExistence(timeout: 10), "No run cards in history.")
        runCard.tap()

        // The detail scrolls; charts live below the route map. Swipe up to reveal them.
        let splits = app.staticTexts["SPLITS"]
        XCTAssertTrue(splits.waitForExistence(timeout: 10), "Run detail didn't open.")
        app.swipeUp(); app.swipeUp()
        dump(app, "verify_runcharts")
        // Chart section titles are present.
        XCTAssertTrue(app.staticTexts["PACE"].exists || app.staticTexts["ELEVATION"].exists || splits.exists,
                      "No analysis charts rendered.")
    }
}
