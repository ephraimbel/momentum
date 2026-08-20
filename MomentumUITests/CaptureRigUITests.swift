import XCTest

/// A capture rig, not a test (2026-08-20): launches the app with arbitrary launch arguments via
/// the XCUITest path — which, unlike bare `simctl launch`, has never once hit the deferred-launch
/// welcome wedge — then simply holds it on screen so an external `simctl io screenshot` can take
/// marketing captures. Drive it per shot:
///
///   TEST_RUNNER_CAPTURE_ARGS="--seed-demo --plan-tab" TEST_RUNNER_CAPTURE_HOLD=45 \
///   xcodebuild test-without-building -only-testing:MomentumUITests/CaptureRigUITests ...
///
/// The hold expires on its own, so a hung capture can never wedge the sim. Excluded from any
/// release-gate meaning: it asserts nothing beyond the app reaching the foreground.
final class CaptureRigUITests: XCTestCase {
    func testHoldForCapture() {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = (env["CAPTURE_ARGS"] ?? "--seed-demo")
            .split(separator: " ").map(String.init)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "app should reach foreground")
        // The hold actively clears permission dialogs (Motion & Fitness is NOT pre-grantable via
        // `simctl privacy` on a fresh container — the whole reason this rig exists is that the
        // XCUITest path can do what simctl cannot).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(TimeInterval(env["CAPTURE_HOLD"].flatMap(Double.init) ?? 60))
        while Date() < deadline {
            for host in [app, springboard] {
                let alert = host.alerts.firstMatch
                guard alert.exists else { continue }
                for label in ["Allow While Using App", "Allow Once", "Allow", "OK"]
                where alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    break
                }
            }
            sleep(2)
        }
    }
}
