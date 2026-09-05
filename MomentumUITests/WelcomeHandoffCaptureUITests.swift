import XCTest

/// A capture harness, not an assertion: photographs the welcome → onboarding hand-off in-process
/// at the highest cadence XCUITest allows and keeps every frame, so the choreography can be read
/// frame by frame from the result bundle (`xcresulttool export attachments`). `simctl io`
/// screenshots run once a second on a loaded machine and its video recorder drops the take when
/// the Simulator window is not on screen, which is exactly when you want this.
///
/// Skipped unless `TEST_RUNNER_CAPTURE_HANDOFF=1` is in the xcodebuild environment; set the
/// simulator appearance with `simctl ui <udid> appearance dark|light` beforehand to read either.
final class WelcomeHandoffCaptureUITests: XCTestCase {

    func testCaptureHandoff() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPTURE_HANDOFF"] == "1",
                          "capture harness — opt in with TEST_RUNNER_CAPTURE_HANDOFF=1")
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--reset-auth"]
        app.launch()
        let start = app.buttons["Build my plan"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        // Let the gallery settle and the actions finish their settle-in before departing.
        Thread.sleep(forTimeInterval: 1.5)
        let t0 = Date()
        start.tap()
        var frames = 0
        while Date().timeIntervalSince(t0) < 3.6 {
            let shot = XCUIScreen.main.screenshot()
            let at = Date().timeIntervalSince(t0)
            let a = XCTAttachment(screenshot: shot)
            a.name = String(format: "handoff_%05.2f", at)
            a.lifetime = .keepAlways
            add(a)
            frames += 1
        }
        XCTAssertGreaterThan(frames, 8, "the capture loop should manage several frames")
    }
}
