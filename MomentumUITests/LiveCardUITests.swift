import XCTest

/// The live tracker's card + controls (2026-08-25 feel pass): one opaque charcoal card with the
/// elapsed time leading, one lavender Pause pill while running (Finish as a small glass stop),
/// Resume + Finish as a pair once paused. Dumps PNGs of both states for visual inspection.
final class LiveCardUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/b8839876-7419-4961-972d-88927a718cdc/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testPauseIsTheOnePrimaryActionAndFinishGrowsOnPause() {
        let app = XCUIApplication()
        // --live-run: straight into a free run; --ui-test-route: synthetic GPS feed.
        app.launchArguments = ["--seed-demo", "--live-run", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()

        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 40), "Live run did not reach tracking.")
        // Flush the Motion prompt through the monitor with a harmless interaction, then settle.
        app.swipeUp()
        sleep(3)
        XCTAssertTrue(app.buttons["Finish"].exists, "Finish (glass stop) missing while running.")
        XCTAssertTrue(app.otherElements["Time"].exists || app.staticTexts.matching(NSPredicate(format: "label == 'Time'")).firstMatch.exists
                      || app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Time'")).firstMatch.exists,
                      "Elapsed time missing from the live card.")
        dump(app, "live_running")

        pause.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5), "Pause did not flip to Resume.")
        XCTAssertTrue(app.buttons["Finish"].exists, "Finish pill missing while paused.")
        dump(app, "live_paused")

        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5), "Resume did not return to Pause.")
    }
}
