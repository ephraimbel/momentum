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

    /// THE FROZEN-PAGE TRIPWIRE: the live DISTANCE and TIME values must actually CHANGE while
    /// recording. The recorder sits behind `.equatable()` walls (`WorkoutRunner` mounts it
    /// `.equatable()`, the stats page re-renders only on `vm.readout` publishes), so an over-broad
    /// `==` or a broken readout publish would freeze every number on the page — while this suite's
    /// control-flip checks and CoreRunFlow's save-screen checks still passed. Two spaced samples
    /// (not one) so a single spurious early change can't satisfy it.
    func testLiveDistanceAndTimeAdvanceWhileRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        // File away a run recovered from a previous suite ending the app mid-session.
        let recoveredDone = app.buttons["Done"].firstMatch
        if recoveredDone.waitForExistence(timeout: 3), app.buttons["Share your run"].exists {
            recoveredDone.tap()
        }

        startRun(in: app)

        let pause = app.buttons["Pause"]
        let startNow = app.buttons["Start now"]
        let deadline = Date().addingTimeInterval(25)
        while !pause.exists && Date() < deadline {
            if startNow.exists && startNow.isHittable { startNow.tap() }
            usleep(300_000)
        }
        XCTAssertTrue(pause.waitForExistence(timeout: 5),
                      "Tracking never began — no live page to sample.")

        // The identifiers live on the stats page's numerals (`liveDistance` on the hero
        // StatNumeral, `liveClock` on the clock text); the covered map page's copies are
        // accessibility-hidden, so each resolves to exactly one element.
        let distance = app.descendants(matching: .any)["liveDistance"].firstMatch
        let clock = app.descendants(matching: .any)["liveClock"].firstMatch
        XCTAssertTrue(distance.waitForExistence(timeout: 10), "The live distance numeral never appeared.")
        XCTAssertTrue(clock.waitForExistence(timeout: 5), "The live clock never appeared.")

        func reading(_ e: XCUIElement) -> String { (e.value as? String) ?? e.label }
        let d0 = reading(distance)
        let t0 = reading(clock)
        XCTAssertFalse(d0.isEmpty, "Distance element exposed no value to sample.")

        // The feed moves ~3 m/s; 12 s ≈ 36 m ≈ 0.02 mi — enough to tick a 2-decimal numeral even
        // if the first sample landed mid-increment. Generous on purpose (CI load).
        sleep(12)
        let d1 = reading(distance)
        let t1 = reading(clock)
        XCTAssertNotEqual(d0, d1,
                          "Live DISTANCE did not change over 12 s of simulated movement — the stats "
                          + "page is frozen (readout not publishing, or an over-broad Equatable).")
        XCTAssertNotEqual(t0, t1,
                          "Live TIME did not advance over 12 s — the clock is frozen.")

        // And still advancing: a page that repainted once at mount then froze fails here.
        sleep(8)
        let d2 = reading(distance)
        XCTAssertNotEqual(d1, d2,
                          "Live DISTANCE stopped changing after its first update — the page froze mid-run.")

        // Leave no mid-run marker behind (this class's other test launches fresh and expects
        // Today, not a recovered save screen): finish the run — the marker clears at finish.
        app.buttons["Finish"].firstMatch.tap()
        let sheetFinish = app.sheets.buttons["Finish"]
        if sheetFinish.waitForExistence(timeout: 6) { sheetFinish.tap() }
        _ = app.buttons["activityDone"].waitForExistence(timeout: 15)
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
