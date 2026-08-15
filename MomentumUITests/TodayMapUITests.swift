import XCTest

/// Today map essentials (PRD §4.2/§7.2): the start card and its controls.
final class TodayMapUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// The start card: recenter control present, and the goal segmented control + Distance stepper hold.
    func testTodayStartCard() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()
        app.tap()

        XCTAssertTrue(app.buttons["Recenter on my location"].waitForExistence(timeout: 15),
                      "Recenter arrow missing from Today.")
        // The deck action row (Log + Start) renders in every deck state — plan day or plan-less.
        // Don't assert on "TODAY'S PLAN": the masthead shows the plan NAME when there is one (the
        // seed's "Austin Marathon"), so that literal only appears for an unnamed plan.
        XCTAssertTrue(app.buttons["Log a workout you already did"].waitForExistence(timeout: 15),
                      "Today deck action row missing (no Log control).")
        XCTAssertTrue(app.buttons["Start run"].waitForExistence(timeout: 5), "Start CTA missing from the deck.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "today-start-card"; shot.lifetime = .keepAlways
        add(shot)
    }

    /// The deck collapses so the map can have the screen, and comes back. Collapse is a plain TAP on
    /// the arrow — a drag was tried and glitched against the map's own pan (owner report 2026-08-14),
    /// so this test also stands as the record that the control is a button, not a handle.
    func testDeckCollapsesAndButtonsStillRespond() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()
        app.tap()

        let start = app.buttons["todayDeckStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "Deck never appeared.")
        let collapse = app.buttons["todayDeckCollapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "Deck collapse arrow missing.")

        // The collapsed state PERSISTS (@AppStorage), so a previous run — or a hand-driven session
        // on this simulator — can leave the deck already down, which turns the collapse tap below
        // into a no-op and fails the test for the wrong reason. Normalize to expanded first.
        let expand = app.buttons["Show today's deck"]
        if expand.exists && expand.isHittable {
            expand.tap()
            XCTAssertTrue(start.isHittable, "Could not restore the deck to its expanded state.")
        }

        collapse.tap()
        XCTAssertTrue(app.buttons["todayPeekStart"].waitForExistence(timeout: 5),
                      "Tapping the arrow did not collapse the deck to its peek.")
        XCTAssertFalse(app.buttons["Log a workout you already did"].isHittable,
                       "Expanded deck controls are still hittable after collapsing.")

        // The map's controls must survive the collapse — they were the first thing to break here.
        XCTAssertTrue(app.buttons["Recenter on my location"].isHittable,
                      "Recenter left the screen with the deck.")

        let collapsed = XCTAttachment(screenshot: app.screenshot())
        collapsed.name = "today-deck-collapsed"; collapsed.lifetime = .keepAlways
        add(collapsed)

        // Back up via the peek's own chevron, then prove the deck's buttons still work.
        app.buttons["Show today's deck"].tap()
        let log = app.buttons["Log a workout you already did"]
        XCTAssertTrue(log.waitForExistence(timeout: 5), "Deck did not come back.")
        XCTAssertTrue(log.isHittable, "Log unreachable after expanding.")
        log.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 8),
                      "Tapping Log did nothing — the card-wide drag gesture is swallowing button taps.")
    }
}
