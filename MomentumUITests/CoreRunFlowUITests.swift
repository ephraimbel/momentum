import XCTest

/// The app's CORE flow, end to end, in one pass: record a ~4-mile run at 6:00/mi (self-contained
/// `--ui-test-run4` GPS feed), watch the trace draw smoothly, Pause → Resume → Finish, edit the save
/// page (name it, attach a photo, make it visible to Everyone, Save), then confirm the run surfaces on
/// the Community feed (route + details) and the Profile grid. A screenshot is attached at every stage.
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
        XCTAssertTrue(app.navigationBars["Save run"].waitForExistence(timeout: 15), "Save screen didn't appear after finishing.")
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

        // 7c. Make it visible to Everyone.
        let visibility = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Workout visibility")).firstMatch
        if visibility.waitForExistence(timeout: 4) {
            scrollToHittable(visibility, in: app)
            visibility.tap()
            sleep(1)
            let everyoneBtn = app.buttons["Everyone"]
            let everyoneItem = app.menuItems["Everyone"]
            if everyoneBtn.waitForExistence(timeout: 3) { everyoneBtn.tap() }
            else if everyoneItem.waitForExistence(timeout: 2) { everyoneItem.tap() }
            attach("7-visibility-everyone")
            XCTAssertTrue(app.buttons["Workout visibility, Everyone"].waitForExistence(timeout: 4),
                          "Visibility didn't switch to Everyone.")
        } else {
            XCTFail("Visibility control not found on the save page.")
        }

        // 7d. Save.
        let save = app.navigationBars.buttons["Save"].firstMatch
        if save.waitForExistence(timeout: 3) { save.tap() }
        else { app.buttons["Save"].firstMatch.tap() }
        sleep(3)                          // completion celebration auto-dismisses (~1.4s) → back to app
        attach("8-after-save")

        // ── 8. Community — the shared run appears (local assembly, default ‘Everyone’ scope) ──
        if app.tabBars.buttons["Community"].waitForExistence(timeout: 8) {
            app.tabBars.buttons["Community"].tap()
        }
        // Force the Global scope in case a prior session persisted ‘Following’.
        if app.buttons["Global"].waitForExistence(timeout: 4) { app.buttons["Global"].tap() }
        sleep(3)                          // async feed assembly on workouts.count change
        // The run carries an honest 24-min backdate (so its saved pace reads ~6:00/mi, not "4 mi in
        // 0:24"), which sorts it below newer seeded posts — so scroll the feed to reach it.
        let feedItem = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", core)).firstMatch
        var feedScrolls = 0
        while !feedItem.exists && feedScrolls < 30 { app.swipeUp(); feedScrolls += 1 }
        attach("9-community")
        XCTAssertTrue(feedItem.waitForExistence(timeout: 6),
                      "The shared run ‘\(title)’ did not appear on the Community feed.")
        // Open the post's reading view (full-size route+photo carousel) by tapping its title — tapping
        // the title opens PostDetailView, not the comment sheet. Dismiss with ‘Done’ so nothing covers
        // the Profile grid next.
        feedItem.tap()
        sleep(2)
        attach("10-community-post-detail")
        if app.buttons["Done"].waitForExistence(timeout: 4) { app.buttons["Done"].tap() }
        sleep(1)

        // ── 9. Profile — the run is the newest tile in the grid ───────────────────────
        if app.tabBars.buttons["Profile"].waitForExistence(timeout: 8) {
            app.tabBars.buttons["Profile"].tap()
        } else {
            app.tabBars.buttons.element(boundBy: 4).tap()   // Profile is the last tab
        }
        sleep(2)
        attach("11-profile")
        let runTile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Run,")).firstMatch
        XCTAssertTrue(runTile.waitForExistence(timeout: 12), "The run tile did not appear on the Profile grid.")
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
