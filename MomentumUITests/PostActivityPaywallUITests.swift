import XCTest

/// **The paywall must never throw an athlete out of their finished activity.**
///
/// Reported 2026-08-22: tapping a Pro-gated control on a post-activity page dumped the athlete out
/// of the page entirely. The cause was presentation ownership. `RootView` hosts the paywall for the
/// app, but it cannot present on top of a context that is itself a cover or a full-screen overlay,
/// and the save editors live inside exactly such a context (the recorder overlay, the crash-recovery
/// cover, the manual-log review). Only `CardioSaveView` hosted its own, so on the strength and timed
/// editors a locked tap set `presentedFeature` with **no live host**: nothing appeared, the feature
/// stayed set, and the paywall finally rose the instant the editor closed and the root host came
/// back — which reads exactly as "the paywall kicked me out of my workout".
///
/// The fix is `.nestedPaywallHost()` on each container (see `NestedPaywallHost.swift`). What this
/// suite pins is the behaviour, per activity type, not the mechanism:
///
///   1. A locked tap on a post-activity page **shows the paywall**.
///   2. Dismissing it **returns to that same page**, with the athlete's work intact.
final class PostActivityPaywallUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    // MARK: The two activity families that carry a locked control

    func testCardioSaveScreenKeepsItsPlaceThroughThePaywall() {
        runPaywallRoundTrip(launchArguments: ["--reset-store", "--seed-demo", "--debug-free", "--save-screen"],
                            activity: "the run save editor")
    }

    func testStrengthSaveScreenKeepsItsPlaceThroughThePaywall() {
        runPaywallRoundTrip(launchArguments: ["--reset-store", "--seed-demo", "--debug-free", "--strength-save"],
                            activity: "the strength save editor")
    }

    // MARK: The round trip

    private func runPaywallRoundTrip(launchArguments: [String], activity: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchArguments = launchArguments
        app.launch()

        // Every save editor — cardio, strength, timed — carries this exact description field, which
        // makes it the one marker that means "still on the post-activity page" for any activity.
        // Matched across element types on purpose: a vertical-axis TextField resolves as a textView
        // or a textField depending on whether it has grown past one line.
        let editorMarker = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR placeholderValue CONTAINS[c] %@",
                        "why did this one matter", "why did this one matter")).firstMatch
        XCTAssertTrue(editorMarker.waitForExistence(timeout: 40),
                      "Expected to land on \(activity).", file: file, line: line)

        // The free-tier teaser for the coach read — the locked control the athlete actually taps.
        let coachRead = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Coach read")).firstMatch
        XCTAssertTrue(scrollTo(coachRead, in: app),
                      "Couldn't reach the locked Coach read control on \(activity).",
                      file: file, line: line)
        coachRead.tap()

        // 1. THE PAYWALL ACTUALLY APPEARS. On the strength editor this used to show nothing at all.
        let restore = app.buttons["Restore"].firstMatch
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(waitFor({ restore.exists || close.exists }, timeout: 12),
                      "The paywall never presented from \(activity) — the locked tap went nowhere.",
                      file: file, line: line)

        // 2. DISMISSING IT RETURNS TO THE SAME PAGE — the whole point of the report.
        XCTAssertTrue(close.waitForExistence(timeout: 5),
                      "The paywall must offer a way back.", file: file, line: line)
        close.tap()

        XCTAssertTrue(waitFor({ editorMarker.exists }, timeout: 12),
                      "Closing the paywall left \(activity) — the athlete must land back where they were.",
                      file: file, line: line)
        // And the page is live, not a husk: the locked control is reachable again.
        XCTAssertTrue(scrollTo(coachRead, in: app),
                      "\(activity) came back but isn't interactive.", file: file, line: line)
    }

    // MARK: Helpers

    /// Poll a condition — `waitForExistence` can't express "either of these two".
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    /// Swipe until the element is hittable. The locked card sits below the fold on both editors,
    /// and how far down depends on the seeded activity, so a fixed number of swipes is not enough.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> Bool {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }
}
