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

    /// The notifications beat, on a fresh install: the mock banner dropping into the phone
    /// (0.6 s after the page lands) and then the SYSTEM permission alert after "Turn on
    /// reminders". A fresh simulator is the only place the alert can be seen — iOS shows it
    /// once per install, and every earlier answer (a walker's "Allow", a previous run) is final.
    func testCaptureNotificationsBeat() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPTURE_HANDOFF"] == "1",
                          "capture harness — opt in with TEST_RUNNER_CAPTURE_HANDOFF=1")
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-notifications"]
        let t0 = Date()
        app.launch()
        var frames = 0
        func snap(_ tag: String) {
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = String(format: "%@_%05.2f", tag, Date().timeIntervalSince(t0)); a.lifetime = .keepAlways; add(a); frames += 1
        }
        // From launch: the page lands, then the banner drops in 0.6 s later.
        while Date().timeIntervalSince(t0) < 5.5 { snap("banner") }
        let turnOn = app.buttons["Turn on reminders"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 20))
        turnOn.tap()
        while Date().timeIntervalSince(t0) < 8.5 { snap("alert") }
        // Whatever the alert says, answer it so the app is not left mid-prompt.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { snap("alert"); allow.tap() }
        XCTAssertGreaterThan(frames, 6)
    }

    /// The paywall tour's departure: "Try now" flares the deck's glass to white and checkout
    /// dissolves in beneath (paywall re-cast 2026-09-05).
    func testCaptureTourDeparture() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPTURE_HANDOFF"] == "1",
                          "capture harness — opt in with TEST_RUNNER_CAPTURE_HANDOFF=1")
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-free", "--paywall-onboarding"]
        app.launch()
        let tryNow = app.buttons["Try now"]
        XCTAssertTrue(tryNow.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2.5)
        let t0 = Date()
        var frames = 0
        func snap(_ tag: String) {
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = String(format: "%@_%05.2f", tag, Date().timeIntervalSince(t0)); a.lifetime = .keepAlways; add(a); frames += 1
        }
        snap("tour")
        tryNow.tap()
        while Date().timeIntervalSince(t0) < 2.6 { snap("depart") }
        XCTAssertGreaterThan(frames, 6)
    }
}
