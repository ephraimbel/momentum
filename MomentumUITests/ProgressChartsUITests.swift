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

    /// The consistency heatmap collapses its 112 color-only cells into ONE VoiceOver element with an
    /// active-days summary (PRD §13.4). Verify that element is actually exposed with a value — proof
    /// the iridescence isn't the sole carrier of meaning.
    func testHeatmapExposesVoiceOverSummary() {
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

        let progressTab = app.tabBars.buttons["Progress"]
        XCTAssertTrue(progressTab.waitForExistence(timeout: 15), "Progress tab not found.")
        progressTab.tap()

        // Scroll down until the collapsed heatmap element (value "N of M days active…") appears.
        let summary = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS[c] %@", "days active")).firstMatch
        var found = summary.waitForExistence(timeout: 3)
        var attempts = 0
        while !found && attempts < 6 {
            app.swipeUp()
            found = summary.exists
            attempts += 1
        }
        XCTAssertTrue(found, "Heatmap VoiceOver summary element not exposed.")
    }

    /// The recovery/readiness card (PRD §4.8) renders in the Pro analytics block with a readiness
    /// band + score exposed to VoiceOver. --seed-demo grants Pro and enough history for `hasData`.
    func testRecoveryCardRenders() {
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

        let progressTab = app.tabBars.buttons["Progress"]
        XCTAssertTrue(progressTab.waitForExistence(timeout: 15), "Progress tab not found.")
        progressTab.tap()

        // The card's accessibility label is "Recovery, <band>" with a "Readiness N of 100" value.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Recovery'")).firstMatch
        var found = card.waitForExistence(timeout: 3)
        var attempts = 0
        while !found && attempts < 6 {
            app.swipeUp()
            found = card.exists
            attempts += 1
        }
        XCTAssertTrue(found, "Recovery readiness card not exposed.")
        let value = card.value as? String ?? ""
        XCTAssertTrue(value.contains("Readiness"), "Recovery card missing its readiness value (got: \(value)).")
    }
}
