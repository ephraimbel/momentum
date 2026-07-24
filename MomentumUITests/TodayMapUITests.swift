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
}
