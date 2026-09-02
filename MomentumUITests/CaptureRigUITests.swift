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
    func testHoldForCapture() throws {
        let env = ProcessInfo.processInfo.environment
        guard let captureArguments = env["CAPTURE_ARGS"] else {
            throw XCTSkip("Capture rig only; set TEST_RUNNER_CAPTURE_ARGS to run it")
        }
        let app = XCUIApplication()
        app.launchArguments = captureArguments
            .split(separator: " ").map(String.init)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "app should reach foreground")
        // The hold actively clears permission dialogs (Motion & Fitness is NOT pre-grantable via
        // `simctl privacy` on a fresh container — the whole reason this rig exists is that the
        // XCUITest path can do what simctl cannot).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let began = Date()
        let deadline = began.addingTimeInterval(TimeInterval(env["CAPTURE_HOLD"].flatMap(Double.init) ?? 60))
        // CAPTURE_SWIPE_Y=<0..1>: ~12s in, drag right-to-left across that screen height once —
        // lets an external screenshot verify paged/swipeable strips without a bespoke test.
        var swiped = false
        while Date() < deadline {
            // A clean-keychain launch parks on the welcome film's "Continue as <athlete>" button
            // (no token to auto-continue on). Tap through it so seeded captures land in the app.
            let welcomeContinue = app.buttons
                .matching(NSPredicate(format: "label BEGINSWITH 'Continue as'")).firstMatch
            if welcomeContinue.exists { welcomeContinue.tap() }
            // Swipe only once safely IN the app — firing while welcome is still up burns the
            // one drag on the film (exactly what a first verification run did).
            else if !swiped, let y = env["CAPTURE_SWIPE_Y"].flatMap(Double.init),
                    Date() > began.addingTimeInterval(15) {
                // Prefer the element itself (hit-tested by the AX tree) over blind coordinates.
                let strip = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH 'Training block'")).firstMatch
                if strip.exists {
                    NSLog("CAPTURE_SWIPE: strip frame \(strip.frame)")
                    strip.swipeLeft()
                } else {
                    NSLog("CAPTURE_SWIPE: strip NOT FOUND, coordinate fallback")
                    let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: y))
                    let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: y))
                    from.press(forDuration: 0.05, thenDragTo: to)
                }
                swiped = true
            }
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
