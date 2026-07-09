import XCTest

/// End-to-end check that a **guided structured run** actually coaches the athlete through its steps
/// (running-excellence R1). Launches straight into a 6×400 m interval session on a synthetic GPS
/// track, then drives the live step banner warm-up → reps → recovery → cool-down → complete via the
/// Skip control — verifying the real `StructuredWorkoutBuilder` + `StructuredRunTracker` +
/// `CardioViewModel` + banner path, not just the unit-level logic.
final class StructuredRunUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testGuidedIntervalSessionAdvancesThroughSteps() {
        let app = XCUIApplication()
        // Seed a profile, feed a deterministic moving GPS track (self-authorizes, no permission alert),
        // and launch directly into the guided interval session.
        app.launchArguments = ["--seed-demo", "--ui-test-route", "--ui-test-structured-run"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        // Reach the tracking screen: the acquiring gate auto-advances once the synthetic GPS locks;
        // tap "Start now" along the way if it's still showing. The Skip control only exists once the
        // guided run is live.
        let skip = app.buttons["Skip step"]
        let startNow = app.buttons["Start now"]
        let deadline = Date().addingTimeInterval(30)
        while !skip.exists && Date() < deadline {
            if startNow.exists && startNow.isHittable { startNow.tap() }
            usleep(300_000)
        }
        XCTAssertTrue(skip.waitForExistence(timeout: 5),
                      "The guided-run step banner (with Skip) never appeared once tracking began.")

        // The session opens on the warm-up.
        XCTAssertTrue(waitForTitle(app, "WARM UP"),
                      "Structured run should open on the warm-up step. Saw: \(currentTitle(app)).")

        // Skip advances the banner deterministically through the prescription.
        skip.tap()
        XCTAssertTrue(waitForTitle(app, "REP 1 / 6"),
                      "After the warm-up the first rep should begin. Saw: \(currentTitle(app)).")
        skip.tap()
        XCTAssertTrue(waitForTitle(app, "RECOVERY"),
                      "A recovery jog should follow rep 1. Saw: \(currentTitle(app)).")
        skip.tap()
        XCTAssertTrue(waitForTitle(app, "REP 2 / 6"),
                      "Rep 2 should follow the recovery. Saw: \(currentTitle(app)).")

        // Drive the rest of the reps + cool-down to completion.
        var guardCount = 0
        while app.buttons["Skip step"].exists && guardCount < 20 {
            app.buttons["Skip step"].tap()
            guardCount += 1
            usleep(120_000)
        }

        XCTAssertTrue(app.otherElements["structuredComplete"].waitForExistence(timeout: 5)
                      || app.staticTexts["structuredComplete"].waitForExistence(timeout: 1),
                      "After the last step the 'Workout complete' state should show.")
    }

    // MARK: Helpers

    private func currentTitle(_ app: XCUIApplication) -> String {
        app.staticTexts["structuredStepTitle"].exists ? app.staticTexts["structuredStepTitle"].label : "«gone»"
    }

    /// Poll the step-title element until it reads `expected` (the banner updates on the next frame).
    private func waitForTitle(_ app: XCUIApplication, _ expected: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts["structuredStepTitle"].label == expected { return true }
            usleep(150_000)
        }
        return false
    }
}
