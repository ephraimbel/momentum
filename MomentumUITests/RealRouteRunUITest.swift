import XCTest

/// Drives a full cardio run against a **real simulated GPS route** (feed `xcrun simctl location booted
/// run "City Run"` from the shell just before running this). Captures the live purple trace as it
/// draws and the finished-route summary — the visual check for the Kalman filter + Mapbox map matching
/// (§8.3/§8.5). Not part of the normal suite; run explicitly.
final class RealRouteRunUITest: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testRealRouteRun() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()

        // Start a run from Today.
        let startRun = app.buttons["Start run"]
        XCTAssertTrue(startRun.waitForExistence(timeout: 25), "Start run button never appeared.")
        startRun.tap()

        // Acquiring gate — capture it, then skip the wait with "Start now" if it's shown.
        let startNow = app.buttons["Start now"]
        if startNow.waitForExistence(timeout: 20) {
            attach(app.screenshot(), "1-acquiring")
            startNow.tap()
        }

        // Countdown → tracking. The Finish button is only present once recording.
        let finish = app.buttons["Finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 25), "Never reached the tracking state.")

        // Let the trace grow as the simulated route moves — capture early and later.
        sleep(20)
        attach(app.screenshot(), "2-tracking-early")
        sleep(40)
        attach(app.screenshot(), "3-tracking-late")

        // Finish → confirm in the dialog.
        finish.tap()
        // The confirmation dialog also has a "Finish" (destructive). Tap the last matching button.
        let dialogFinish = app.buttons.matching(identifier: "Finish").allElementsBoundByIndex.last
        dialogFinish?.tap()

        // Summary appears immediately with the raw trace; wait for map matching to swap in the snapped
        // route (a background network call).
        sleep(14)
        attach(app.screenshot(), "4-summary-route")
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
