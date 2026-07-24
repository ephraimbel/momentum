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
