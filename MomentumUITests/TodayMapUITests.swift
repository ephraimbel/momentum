import XCTest

/// Today map essentials (PRD §4.2/§7.2). The "Suggest a loop" entry is **hidden** for now (loop quality
/// isn't good enough), so the loop suggester is exercised via the `--loop` debug deep link — the code is
/// intact and this guards it for when the feature returns.
final class TodayMapUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// The inline loop suggester still works (via `--loop`): it routes, renders on the Today map, and
    /// closing returns to the normal start card.
    func testLoopModeViaDeepLink() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--loop"]
        app.launch()

        // Loop mode opens; the distance picker shows immediately, loops stream in.
        let opened = app.buttons["5K"].waitForExistence(timeout: 15) || app.staticTexts["5K"].exists
        XCTAssertTrue(opened, "Loop mode didn't open via --loop.")
        let use = app.buttons["Use this route"]
        XCTAssertTrue(use.waitForExistence(timeout: 30), "Loop candidates never finished routing.")
        XCTAssertTrue(app.buttons["10K"].exists && app.buttons["Shuffle"].exists,
                      "Loop controls (distance / shuffle) missing.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "loop-mode"; shot.lifetime = .keepAlways
        add(shot)

        // Closing returns to the normal Today start card.
        app.buttons["Close loop suggestions"].tap()
        XCTAssertTrue(app.buttons["Start run"].waitForExistence(timeout: 5), "Didn't return to Today.")
    }

    /// The start card: recenter control present, and the goal segmented control + Distance stepper hold.
    func testTodayStartCard() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()
        app.tap()

        XCTAssertTrue(app.buttons["Recenter on my location"].waitForExistence(timeout: 15),
                      "Recenter arrow missing from Today.")
        // The deck (post-redesign: plan → Start → utility line). With a seeded plan today the hero
        // is the prescription + its Start CTA; the free-run goal segments only exist on plan-less days.
        XCTAssertTrue(app.staticTexts["TODAY'S PLAN"].waitForExistence(timeout: 15)
                      || app.buttons["Distance"].waitForExistence(timeout: 2),
                      "Today deck missing (no plan hero, no quick-start goals).")
        XCTAssertTrue(app.buttons["Start run"].waitForExistence(timeout: 5), "Start CTA missing from the deck.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "today-start-card"; shot.lifetime = .keepAlways
        add(shot)
    }
}
