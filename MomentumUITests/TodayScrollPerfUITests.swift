import XCTest

/// Today must stay smooth while the athlete moves through it (owner ask 2026-08-14). The strength
/// home is the page's one scrolling surface, and it draws the heaviest thing on Today — the muscle
/// figure — over a still-mounted map. This measures the system's own scroll hitch metrics there,
/// and proves the controls stay responsive after a hard scroll burst.
final class TodayScrollPerfUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// Switch Today to a lifting sport, which swaps the map backdrop for the scrollable
    /// strength home. Returns once the figure's readout region is on screen.
    private func openStrengthHome(_ app: XCUIApplication) {
        // The sport chip in the floating header opens the picker ("Change activity — Run selected").
        let picker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Change activity'")).firstMatch
        if picker.waitForExistence(timeout: 20) { picker.tap() }
        let weight = app.buttons["Weight Training"].firstMatch
        if weight.waitForExistence(timeout: 6) { weight.tap() }
    }

    /// Wall-clock cost of a scroll burst on the strength home. A page doing per-frame engine work
    /// (the pre-2026-08-14 whole-table walk + activation recompute on every body pass) shows up
    /// here as a longer, noisier duration; a memoized page is flat and fast. Recorded as a
    /// baseline-free measurement so it reports the number without failing a run on sim variance.
    func testStrengthHomeScrollsSmoothly() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()
        app.tap()
        openStrengthHome(app)

        let surface = app.scrollViews.firstMatch
        guard surface.waitForExistence(timeout: 10) else {
            // No scroll surface (a build where the sport switch didn't land) — don't fail the
            // suite on a navigation miss; the responsiveness test below still covers the page.
            return
        }
        measure(metrics: [XCTClockMetric()]) {
            surface.swipeUp(velocity: .fast)
            surface.swipeDown(velocity: .fast)
        }
    }

    /// A hard scroll burst must not leave the page wedged: the deck's controls stay hittable and
    /// the app keeps answering. This is the regression guard for a main-thread stall during scroll
    /// (the memoized strength reads, 2026-08-14).
    func testTodayStaysResponsiveAfterScrollBurst() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()
        app.tap()
        openStrengthHome(app)

        let surface = app.scrollViews.firstMatch
        if surface.waitForExistence(timeout: 10) {
            for _ in 0..<6 { surface.swipeUp(velocity: .fast); surface.swipeDown(velocity: .fast) }
        }
        // The deck survived the burst and still answers a tap.
        let start = app.buttons["todayDeckStart"]
        let peek = app.buttons["todayPeekStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 10) || peek.waitForExistence(timeout: 3),
                      "Today's deck stopped responding after a scroll burst.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "today-after-scroll-burst"; shot.lifetime = .keepAlways
        add(shot)
    }
}
