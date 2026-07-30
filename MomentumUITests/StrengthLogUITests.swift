import XCTest

/// End-to-end check that a logged set's ✓ **toggles** — tap to log, tap again to un-log — using the
/// real touch path (XCUITest taps the accessibility frame, not a synthetic mouse click). The control
/// exposes its state via accessibility label ("Log set" ↔ "Set logged. Double-tap to undo."), so a
/// pass means the green ✓ a user taps both logs and un-logs the set.
final class StrengthLogUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLoggingSetTogglesOnAndOff() {
        let app = XCUIApplication()
        // `--ui-test-strength` opens Today in strength (no picker navigation); `--ui-test-route`
        // self-authorizes location so that alert never interrupts the flow.
        app.launchArguments = ["--reset-store", "--seed-demo", "--ui-test-strength", "--ui-test-route"]
        // Dismiss any remaining system alert (e.g. notifications) on the next interaction.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()   // trigger the interruption monitor if a permission alert is up

        // 1. Start a free strength workout.
        let start = app.buttons["Start workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "Strength 'Start workout' button not found.")
        start.tap()

        // 2. The exercise library auto-opens on a free start — pick a seeded exercise and add it.
        let bench = app.staticTexts["Barbell Bench Press"].firstMatch   // library may list it under
        // more than one section (recents + all) — any instance is the same exercise
        XCTAssertTrue(bench.waitForExistence(timeout: 15), "Exercise library / seeded exercise not found.")
        bench.tap()
        let add = app.buttons["Add 1"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add button did not update after selecting an exercise.")
        add.tap()

        // 3. A set row appears with an unchecked ✓.
        let log = app.buttons["Log set"]
        XCTAssertTrue(log.waitForExistence(timeout: 15), "Set row's 'Log set' ✓ not found.")

        // 4. Tap ✓ → the set is logged (the green, undoable state).
        log.tap()
        let logged = app.buttons["Set logged. Double-tap to undo."]
        XCTAssertTrue(logged.waitForExistence(timeout: 5), "Tapping ✓ did not mark the set logged.")
        attach(app, name: "set-logged-green")   // visual proof the ✓ turns green

        // 5. Tap ✓ again → it un-logs (the new toggle capability).
        logged.tap()
        XCTAssertTrue(app.buttons["Log set"].waitForExistence(timeout: 5),
                      "Tapping a logged set's ✓ did not un-log it — the checkmark is not toggleable.")
        attach(app, name: "set-unchecked")   // visual proof it reverts to a grey ✓
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
