import XCTest

/// End-to-end check that the **Pause/Resume control on the live run screen actually responds** —
/// the case that's easy to break because the button sits, transparent, over an interactive MapKit
/// map (see `OversizedButton` + `CardioTrackingView`). XCUITest taps the button's real frame via
/// the system touch path (not a synthetic mouse click), so a pass means a finger-tap works too.
final class RunPauseUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testPauseAndResumeDuringRun() {
        let app = XCUIApplication()
        // `--ui-test-route` feeds a deterministic moving GPS track (DEBUG hook in LocationService) so
        // the run engine reaches `.tracking` without relying on the simulator's flaky CoreLocation —
        // and it self-authorizes, so no permission alert interrupts the flow.
        app.launchArguments = ["--seed-demo", "--ui-test-route"]
        // Safety net for any other system alert (e.g. notifications) that could interrupt the flow.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        // 1. Make sure we're in Run mode, then start the run.
        startRun(in: app)

        // 2. Reach the tracking screen. A simulated *moving* location (fed via `simctl location
        // start` by the test runner) makes the acquiring gate auto-advance once GPS locks; if it
        // hasn't locked yet, "Start now" skips the wait. Poll for the Pause button, tapping
        // "Start now" along the way if it's still showing.
        let pause = app.buttons["Pause"]
        let startNow = app.buttons["Start now"]
        let deadline = Date().addingTimeInterval(25)
        while !pause.exists && Date() < deadline {
            if startNow.exists && startNow.isHittable { startNow.tap() }
            usleep(300_000)
        }
        XCTAssertTrue(pause.waitForExistence(timeout: 5),
                      "Expected the live-run Pause button to appear once tracking begins.")
        XCTAssertFalse(app.buttons["Resume"].exists, "Run should not start paused.")

        // 4. THE CHECK: tapping Pause must flip the control to Resume (i.e. the tap was received).
        pause.tap()
        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5),
                      "Tapping Pause did not pause the run — the button never became 'Resume'. "
                      + "This is the transparent-button-over-map hit-testing regression.")
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 3),
                      "Paused state label should be shown while paused.")

        // 5. And Resume must flip it back — the control round-trips.
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5),
                      "Tapping Resume did not resume the run — the button never became 'Pause' again.")
    }

    /// Picks Run if it isn't already selected, then taps the start button.
    private func startRun(in app: XCUIApplication) {
        let startRun = app.buttons["Start run"]
        if !startRun.waitForExistence(timeout: 10) {
            // Not in a running discipline — open the activity picker and choose Run.
            app.buttons["Run"].firstMatch.tap()                 // the activity-selector pill shows the current sport…
            let runCard = app.buttons["Run"]
            if runCard.waitForExistence(timeout: 5) { runCard.tap() }
        }
        XCTAssertTrue(startRun.waitForExistence(timeout: 10), "Could not find the 'Start run' button.")
        startRun.tap()
    }
}
