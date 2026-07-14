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

        // The trend charts should render on the default Trends segment. The default range decides the
        // granularity word — "Daily …" (1W) or "Weekly …" (wider windows) — so assert on the metric,
        // not the prefix, and the test stays valid whatever the default window is.
        let load = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "training load")).firstMatch
        XCTAssertTrue(load.waitForExistence(timeout: 10), "Training-load chart not found.")
        let distance = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "distance")).firstMatch
        XCTAssertTrue(distance.waitForExistence(timeout: 5), "Distance chart not found.")
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

        // The consistency summary lives on Profile → Highlights (decision: consistency is a
        // Profile section, not a Progress chart) — the original assertion scrolled the wrong tab.
        let profileTab = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15), "Profile tab not found.")
        profileTab.tap()
        let highlights = app.buttons["Highlights"]
        XCTAssertTrue(highlights.waitForExistence(timeout: 10), "Highlights tab not found.")
        highlights.tap()

        // Scroll down until the heatmap element (value "N of M days active…") appears.
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

        // Anchor on the readiness VALUE: a bare "Recovery" label also matches the HR-zones Z1
        // row ("Recovery · Active recovery"), whose value is empty.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS 'Readiness'")).firstMatch
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
