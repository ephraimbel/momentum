import XCTest

/// The app's CORE flow, end to end, in one pass: record a ~4-mile run at 6:00/mi (self-contained
/// `--ui-test-run4` GPS feed), watch the trace draw smoothly, Pause → Resume → Finish, edit the save
/// page (name it, attach a photo, Save), then confirm the run surfaces on the Profile grid and the
/// Fuel tab renders. Solo-first (2026-07-16): the social steps left with the community back-burner.
/// A screenshot is attached at every stage.
///
/// `continueAfterFailure = true` so the run walks the WHOLE flow and captures every screenshot even if
/// one assertion trips — this is a verification pass, not a fail-fast gate.
///
/// Pause/Resume is exercised AFTER the fast burst has drawn the full 4-mile trace (during the slow
/// real-time tail) so the recorded polyline is one continuous smooth sweep — pausing mid-burst would
/// (correctly) skip the fixes fed while paused and leave an expected-but-confusing gap in the trace.
final class CoreRunFlowUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = true }

    func testRunToSaveToCommunityToProfile() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-run4"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        let core = "E2E Run 4mi"          // unique core → cross-screen CONTAINS anchor
        let title = "ZZ \(core)"

        // ── 1. Start the run from Today ───────────────────────────────────────────────
        let startRun = app.buttons["Start run"]
        XCTAssertTrue(startRun.waitForExistence(timeout: 25), "‘Start run’ never appeared on Today.")
        attach("0-today")
        startRun.tap()

        // ── 2. Acquiring gate → tap ‘Start now’ if it shows (it often auto-advances on first fix) ──
        let startNow = app.buttons["Start now"]
        if startNow.waitForExistence(timeout: 6) { attach("1-acquiring"); startNow.tap() }

        // ── 3. Reach tracking (Finish present once recording, after the 3-2-1 countdown) ──
        let finish = app.buttons["Finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 30), "Never reached the tracking state.")
        // Clear iOS's location prompt (Mapbox requests authorization independently of the app) — a
        // benign tap on the metrics panel lets the interruption monitor fire before the screenshots.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()

        // Early frame — a short, clean single-pass arc: an unambiguous check that the dot sits at the
        // tip of a non-overlapping trace before the sweep gets long.
        sleep(14)
        attach("1-early-trace")

        // ── 4. Draw the whole ~4-mile trace in one continuous sweep (no pause gap) ──────
        sleep(84)
        attach("2-tracking-trace")        // ~4 mi, smooth

        // ── 5. Pause → Resume (burst done → real-time tail → negligible trace gap) ──────
        let pause = app.buttons["Pause"]
        if pause.waitForExistence(timeout: 6) {
            pause.tap()
            let resume = app.buttons["Resume"]
            if !resume.waitForExistence(timeout: 5), pause.exists {
                // On a pristine simulator a first-run permission alert can appear right here; the
                // interruption monitor dismisses it but CONSUMES the tap. One re-tap covers it.
                pause.tap()
            }
            XCTAssertTrue(resume.waitForExistence(timeout: 5), "Tapping Pause did not flip the control to Resume.")
            attach("3-paused")
            resume.tap()
            XCTAssertTrue(pause.waitForExistence(timeout: 5), "Tapping Resume did not flip the control back to Pause.")
        } else {
            XCTFail("Pause button never appeared — the run never fully entered tracking.")
        }
        sleep(2)
        attach("4-tracking-4mi")

        // ── 6. Finish → confirm in the action sheet ───────────────────────────────────
        finish.tap()
        let sheetFinish = app.sheets.buttons["Finish"]
        if sheetFinish.waitForExistence(timeout: 6) { sheetFinish.tap() }
        else { app.buttons["Finish"].firstMatch.tap() }   // fallback if not an action sheet

        // ── 7. Save / edit page ───────────────────────────────────────────────────────
        // Titled with the discipline, not "Save run": the recording is already on disk by the time
        // this appears, so a filing verb described work the athlete wasn't doing. This assertion
        // still said "Save run" and had been failing the whole end-to-end guard ever since.
        XCTAssertTrue(app.buttons["activityDone"].waitForExistence(timeout: 15), "Save screen didn't appear after finishing.")
        sleep(2)
        attach("5-save-screen")           // top of the page — hero route map

        // 7a. Attach a photo (DEBUG hook attaches a bundled image under --ui-test-run4).
        let addPhotos = app.buttons["Add photos"]
        if addPhotos.waitForExistence(timeout: 4) {
            scrollToHittable(addPhotos, in: app)
            addPhotos.tap()
            sleep(1)
            attach("6-photo-added")
        } else {
            attach("6-no-add-photos-button")
        }

        // 7b. Name it (clear the default, type a unique title, ‘\n’ submits + dismisses the keyboard).
        let titleField = app.textFields["Name your run"]
        if titleField.waitForExistence(timeout: 5) {
            scrollToHittable(titleField, in: app)
            titleField.tap()
            // The tap doesn't always take focus first try (SwiftUI TextField + keyboard animation) —
            // confirm the keyboard is up before typing, retapping once if not, so the title reliably
            // becomes our unique string (a missed focus leaves the default, breaking the feed lookup).
            if !app.keyboards.firstMatch.waitForExistence(timeout: 3) {
                titleField.tap()
                _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            }
            titleField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30))
            titleField.typeText(title + "\n")
        } else {
            XCTFail("Title field ‘Name your run’ not found.")
        }

        // 7c. The share moment: community came BACK (2026-07-29 reintegration), so the save page
        // carries the visibility control again in community-enabled builds. This assertion pinned
        // the solo era's absence and had been failing since the row returned (stale, fixed
        // 2026-08-07 — first suite run to catch it).
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Workout visibility")).firstMatch.exists,
            "The visibility control (ShareVisibilityRow) should be on the save page with community enabled.")

        // 7d. Save — the confirmation action is "Done" (it was renamed with the title above).
        let save = app.buttons["activityDone"].firstMatch
        if save.waitForExistence(timeout: 3) { save.tap() }
        else { app.buttons["Done"].firstMatch.tap() }
        sleep(3)                          // completion celebration auto-dismisses (~1.4s) → back to app
        attach("8-after-save")

        // 7d². The first-save soft-ask ("Enjoying momentum?") raises ~0.6s after the recorder
        // clears on a fresh container. It owns the whole screen — left up, it silently swallowed
        // the Profile tab tap below and failed the grid assertion (found 2026-08-19).
        if app.staticTexts["Enjoying momentum?"].waitForExistence(timeout: 3) {
            app.buttons["Maybe later"].tap()
            sleep(1)
            attach("8a-rating-prompt-dismissed")
        }

        // 7e. Tap through any award unlocks the run earned. They present at the root the moment the
        // save cover clears, and they own the whole screen until dismissed — exactly what a real
        // athlete taps through, and what the rest of this test has to get past before it can see
        // the tab bar at all.
        var awardTaps = 0
        while app.staticTexts["AWARD EARNED"].waitForExistence(timeout: 3), awardTaps < 8 {
            app.staticTexts["AWARD EARNED"].tap()
            awardTaps += 1
            sleep(1)
        }
        if awardTaps > 0 { attach("8b-after-awards") }

        // ── 8. There is NO Community tab — the bar is Today · Plan · Progress · Fuel · Profile.
        XCTAssertFalse(app.tabBars.buttons["Community"].exists,
                       "The Community tab must not ship in v1 (back-burnered).")

        // ── 9. Profile — the run is the newest tile in the grid (Profile is a tab again).
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 8), "Profile tab missing.")
        app.tabBars.buttons["Profile"].tap()
        sleep(2)
        attach("9-profile")
        // The Grid/Highlights pane PERSISTS (@AppStorage com.momentum.profile.gridTab) — a prior
        // test on the same container can leave the profile on Highlights, where no tile exists.
        // Select the grid pane explicitly instead of assuming the default (found 2026-08-20).
        if app.buttons["Grid"].waitForExistence(timeout: 4) { app.buttons["Grid"].tap(); sleep(1) }
        let runTile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Run,")).firstMatch
        XCTAssertTrue(runTile.waitForExistence(timeout: 12), "The run tile did not appear on the Profile grid.")

        // ── 10. Fuel — the tab renders its readout ────────────────────────────────────
        if app.tabBars.buttons["Fuel"].waitForExistence(timeout: 6) {
            app.tabBars.buttons["Fuel"].tap()
            sleep(2)
            attach("10-fuel-tab")
        }
    }

    // MARK: Helpers

    /// Swipe the scroll content up (a low-start coordinate drag, so it grabs the ScrollView rather
    /// than the Mapbox hero map at the top) until `el` is hittable, bounded so it never spins.
    private func scrollToHittable(_ el: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        var n = 0
        while el.exists && !el.isHittable && n < maxSwipes {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
            n += 1
        }
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
