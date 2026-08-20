import XCTest

/// Verification probe for the OUT-OF-APP run experience: starts a run (self-contained
/// `--ui-test-run4` GPS feed), then leaves the app and captures what the athlete actually sees —
/// the Dynamic Island while the run records, its expanded presentation, and the pull-down
/// cover-sheet view where the lock-screen Live Activity card renders. Screenshot-driven: the
/// attachments are the deliverable; the assertions only pin that a run reached tracking and the
/// app survived the round trip. Run it alongside `simctl io recordVideo` for motion review.
final class LiveActivityProbeUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = true }

    func testLockScreenSurfacesDuringARun() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-run4"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // Start the run and reach tracking.
        let startRun = app.buttons["Start run"]
        XCTAssertTrue(startRun.waitForExistence(timeout: 25), "'Start run' never appeared on Today.")
        startRun.tap()
        let startNow = app.buttons["Start now"]
        if startNow.waitForExistence(timeout: 6) { startNow.tap() }
        XCTAssertTrue(app.buttons["Finish"].waitForExistence(timeout: 30), "Never reached tracking.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()  // clear location prompt
        sleep(10)                                    // let distance/pace accumulate real values
        attach("0-in-app-tracking")

        // ── Out of the app: Dynamic Island (compact) on the home screen ──────────────
        XCUIDevice.shared.press(.home)
        sleep(3)                                     // island morph settles
        attach("1-home-dynamic-island")

        // Expanded presentation: long-press the island (springboard owns it).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let islandArea = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        islandArea.press(forDuration: 0.8)
        sleep(2)
        attach("2-island-expanded")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap() // dismiss
        sleep(1)

        // ── Cover sheet (the lock-screen presentation of the Live Activity card) ─────
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
            .press(forDuration: 0.05,
                   thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        sleep(3)                                     // let the card's live timer render
        attach("3-cover-sheet-card")
        sleep(5)                                     // second frame proves the timer ticks unaided
        attach("4-cover-sheet-card-later")
        springboard.swipeUp()
        sleep(1)

        // ── Back into the live run: the return trip must land on tracking, not relaunch ──
        app.activate()
        XCTAssertTrue(app.buttons["Finish"].waitForExistence(timeout: 10),
                      "Returning from the lock screen did not land back on the live run.")
        attach("5-back-in-app")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/0ed74c64-03b6-4bda-9433-8ffb673a2b98/scratchpad/la_\(name).png"))
    }
}
