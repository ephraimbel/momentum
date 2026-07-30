import XCTest

/// The Health page's Oura-style tap-throughs (2026-07-23): a vitals tile opens the full
/// month-to-year `TrendDetailSheet` — the line in the vital's domain ink over the personal-band
/// ribbon — and the sleep card's nights section opens the nightly-duration detail. Runs on the
/// demo recovery scenario so every window has data.
final class HealthDetailUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    @discardableResult
    private func swipeUntilFound(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 12) -> Bool {
        var found = element.waitForExistence(timeout: 3)
        var tries = 0
        while !found && tries < attempts {
            app.swipeUp()
            found = element.exists
            tries += 1
        }
        return found
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testVitalAndSleepTapThroughs() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--health-recovery-demo", "--progress-tab", "--progress-health"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 3) { discard.tap() }

        // Sleep first (it sits above the vitals board). The nights section is ONE a11y element
        // whose whole card area opens the detail — no in-plot scrub to dodge here.
        let nights = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Last 7 nights")).firstMatch
        XCTAssertTrue(swipeUntilFound(nights, in: app), "Sleep nights section not found.")
        nights.tap()
        XCTAssertTrue(app.navigationBars["Sleep duration"].waitForExistence(timeout: 6),
                      "Nights tap didn't open the sleep-duration detail.")
        XCTAssertTrue(app.buttons["past year"].waitForExistence(timeout: 4),
                      "Sleep detail's 1Y range missing.")
        attach("sleep-detail-sheet")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Sleep duration"].waitForNonExistence(timeout: 4),
                      "Sleep detail didn't dismiss.")

        // A vitals tile: HRV opens the line-over-band detail, and the year window actually
        // loads (the detail's whole point over the tile's 30-day spark). Off-viewport elements
        // drop out of the AX tree in BOTH directions and a fast descent can overshoot the grid
        // between checks — so search with settling waits, then sweep back up if we sailed past.
        let hrv = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "HRV")).firstMatch
        var found = hrv.waitForExistence(timeout: 2)
        var tries = 0
        while !found && tries < 8 {
            app.swipeUp()
            found = hrv.waitForExistence(timeout: 1)
            tries += 1
        }
        tries = 0
        while !found && tries < 12 {
            app.swipeDown()
            found = hrv.waitForExistence(timeout: 1)
            tries += 1
        }
        XCTAssertTrue(found, "HRV tile not found.")
        hrv.tap()
        if !app.navigationBars["HRV"].waitForExistence(timeout: 4) { hrv.tap() }
        XCTAssertTrue(app.navigationBars["HRV"].waitForExistence(timeout: 6),
                      "HRV tile tap didn't open its detail sheet.")
        app.buttons["past year"].tap()
        XCTAssertTrue(app.staticTexts["Latest · past year"].waitForExistence(timeout: 6),
                      "1Y window didn't load in the HRV detail.")
        attach("hrv-detail-sheet")
        app.buttons["Done"].tap()
    }
}
