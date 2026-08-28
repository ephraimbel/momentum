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

        // A previous run of this very suite ends the app mid-session — cold launch recovers it
        // into the save screen (zero-lost-workouts is designed behavior). File it away first.
        let recoveredDone = app.buttons["Done"].firstMatch
        if recoveredDone.waitForExistence(timeout: 3), app.buttons["Share your run"].exists {
            recoveredDone.tap()
        }

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

    /// Pausing within 5 s of GO must silence the intro's delayed step call ("Warm up. Ease in."):
    /// it fires from a wall-clock task armed at GO, and it used to bypass the paused guard every
    /// other cue path enforces — speaking mid-pause. It must also stay dropped on resume (the
    /// parked-cue rule: the moment has passed, nothing dumps the instant you resume).
    ///
    /// Named to run FIRST in this class (alphabetical): after the interval test the app is killed
    /// mid-run, and the next launch spends seconds filing the recovered save — enough for the
    /// Pause tap to slip past the 5 s window and trip the timing skip below.
    func testAtTheGunPauseSilencesTheIntroStepCall() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route", "--ui-test-structured-run"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        // Absorb any crash-recovery UX left by a previous suite ending the app mid-run — it has
        // TWO forms (the "Unfinished … found" alert with Save it/Discard, or the recovered save
        // screen), presents asynchronously, and races the deferred structured launch: left in
        // place it consumes the timing-critical Pause tap below (a chronic skip in suite order).
        // File it inside a fixed grace window, then RELAUNCH clean — probing "is the recorder
        // up?" proves nothing, because the alert can land after the recorder is already showing.
        var needsRelaunch = false
        let probe = Date().addingTimeInterval(6)
        while Date() < probe {
            let discard = app.alerts.buttons["Discard"]
            if discard.exists { discard.tap(); needsRelaunch = true; break }
            let done = app.buttons["Done"].firstMatch
            if done.exists, app.buttons["Share your run"].exists { done.tap(); needsRelaunch = true; break }
            usleep(250_000)
        }
        if needsRelaunch {
            app.terminate()
            app.launch()
        }

        // Reach tracking, tapping "Start now" along the way if the gate is still showing.
        let pause = app.buttons["Pause"]
        let startNow = app.buttons["Start now"]
        let deadline = Date().addingTimeInterval(30)
        while !pause.exists && Date() < deadline {
            if startNow.exists && startNow.isHittable { startNow.tap() }
            usleep(200_000)
        }
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Tracking never began.")

        // Pause IMMEDIATELY — inside the 5 s window before the intro's step call fires. One brief
        // settle first: tapping into the pager's mount transition can land on nothing.
        let trackingSeenAt = Date()
        usleep(250_000)
        pause.tap()
        if !app.buttons["Resume"].waitForExistence(timeout: 3), pause.exists {
            // On a pristine simulator a first-run permission alert can appear right here; the
            // interruption monitor dismisses it but CONSUMES the tap. One re-tap covers it (the
            // timing skip below still guards the window).
            pause.tap()
        }
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 4),
                      "Pause tap was not received.")
        let pausedWithinS = Date().timeIntervalSince(trackingSeenAt)
        // Only a pause that landed inside the 5 s intro window exercises the guard; on a machine
        // too loaded to get there in time, skip rather than mis-assert against a legitimate cue.
        try XCTSkipIf(pausedWithinS > 4.0,
                      "Pause landed \(Int(pausedWithinS))s after tracking — outside the 5 s intro window.")

        // Sit paused through the moment the tail would have fired (5 s after GO), plus margin.
        sleep(6)
        let stepCall = app.staticTexts["Warm up. Ease in."]
        XCTAssertFalse(stepCall.exists,
                       "The intro step call surfaced MID-PAUSE — the 5 s intro tail bypassed the "
                       + "paused guard every other cue path enforces.")
        let pausedShot = XCTAttachment(screenshot: app.screenshot())
        pausedShot.name = "paused-at-gun-no-step-call"
        pausedShot.lifetime = .keepAlways
        add(pausedShot)

        // And it stays dropped on resume — parked-cue semantics, never a deferred announcement.
        app.buttons["Resume"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 4), "Resume tap was not received.")
        sleep(3)
        XCTAssertFalse(stepCall.exists,
                       "The intro step call fired ON RESUME — it must be dropped like a parked cue, "
                       + "not deferred.")

        // Leave no mid-run marker for whatever launches next: finish the run (marker clears there).
        app.buttons["Finish"].firstMatch.tap()
        let sheetFinish = app.sheets.buttons["Finish"]
        if sheetFinish.waitForExistence(timeout: 6) { sheetFinish.tap() }
        _ = app.buttons["activityDone"].waitForExistence(timeout: 15)
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
