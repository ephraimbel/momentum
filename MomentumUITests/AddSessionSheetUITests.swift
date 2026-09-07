import XCTest

/// The Add a session sheet (redesigned 2026-09-07 to the house sheet grammar): the masthead, the
/// two-week day grid, the sport chips, the goal stepper, and the receipt line that summarizes the
/// choice above the Add button. Drives the whole form and attaches screenshots of each state.
final class AddSessionSheetUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testFormDrivesTheReceiptAndCommits() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--awards-quiet", "--plan-tab", "--plan-add"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()

        // The masthead speaks the house grammar: the title, and Close beside it.
        XCTAssertTrue(app.staticTexts["Add a session"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.buttons["Close"].exists)
        XCTAssertTrue(app.buttons["Workout library"].exists)
        // The receipt line's accessibility label is "Adding <receipt>".
        XCTAssertTrue(app.staticTexts["Adding Today · Run"].exists, "The receipt opens on today's run.")
        shot(app, "add-session-open")

        // Tomorrow, on the two-week grid (no horizontal strip to scroll).
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let tomorrowLabel = tomorrow.formatted(.dateTime.weekday(.wide).month().day())
        let tomorrowCell = app.buttons[tomorrowLabel]
        XCTAssertTrue(tomorrowCell.exists, "Tomorrow must be on the grid: \(tomorrowLabel)")
        tomorrowCell.tap()
        XCTAssertTrue(tomorrowCell.isSelected)
        let short = tomorrow.formatted(.dateTime.weekday(.abbreviated).day())
        XCTAssertTrue(app.staticTexts["Adding \(short) · Run"].waitForExistence(timeout: 3))

        // Strength, then a duration goal.
        app.buttons["Strength"].tap()
        XCTAssertTrue(app.buttons["Strength"].isSelected)
        XCTAssertFalse(app.buttons["Run"].isSelected)
        XCTAssertTrue(app.staticTexts["Adding \(short) · Strength"].waitForExistence(timeout: 3))
        app.buttons["Duration"].tap()
        XCTAssertTrue(app.buttons["Increase"].waitForExistence(timeout: 3))
        app.buttons["Increase"].tap()
        XCTAssertTrue(app.staticTexts["Adding \(short) · Strength · 35 min"].waitForExistence(timeout: 3))
        shot(app, "add-session-strength-duration")

        // Back to a run with a distance.
        app.buttons["Run"].tap()
        XCTAssertTrue(app.buttons["Distance"].waitForExistence(timeout: 3))
        app.buttons["Distance"].tap()
        XCTAssertTrue(app.buttons["Decrease"].waitForExistence(timeout: 3))
        app.buttons["Decrease"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Adding \(short) · Run · 4.5")).firstMatch
            .waitForExistence(timeout: 3))
        shot(app, "add-session-run-distance")

        // Commit: the sheet closes and the board has the session.
        app.buttons["Add to plan"].tap()
        XCTAssertTrue(app.staticTexts["Add a session"].waitForNonExistence(timeout: 5))
    }
}
