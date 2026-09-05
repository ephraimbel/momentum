import XCTest

/// Real dismissal-driven routes. These deliberately don't sleep between the user's tap and the
/// destination assertion: the UI must sequence its own presentations, in either motion setting.
final class MotionHandoffUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--awards-quiet"] + args
        app.launch()
        ScrollTestSupport.dismissRecoveryIfPresent(app, timeout: 3)
        return app
    }

    func testPlanAddHandsOffToLibrary() {
        let app = launch(["--plan-tab", "--plan-add"])
        let library = app.buttons["Workout library"]
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.tap()
        XCTAssertTrue(app.navigationBars["Workout library"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Add a session"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Workout library"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Plan"].isHittable)
    }

    func testCheckinHandsOffToLifeHappens() {
        let app = launch(["--checkin"])
        let life = app.buttons["Life's in the way — pause or ease your plan"]
        XCTAssertTrue(life.waitForExistence(timeout: 20))
        life.tap()
        XCTAssertTrue(app.navigationBars["Life happens"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["Morning check-in"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Life happens"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Today"].isHittable)
    }

    func testLogComposerHandsOffToDetails() {
        let app = launch(["--log-activity"])
        let adjust = app.buttons["Log it manually"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 20))
        adjust.tap()
        XCTAssertTrue(app.navigationBars["Add a workout"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["What did you do?"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 5))
    }

    func testTodayControlsSurviveRepeatedOpenClose() {
        let app = launch([])
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))
        for _ in 0..<4 {
            let more = app.buttons["More"]
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
            let close = app.buttons["Close controls"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
        }
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Change activity'")).firstMatch
        picker.tap()
        XCTAssertTrue(app.buttons["Weight Training"].waitForExistence(timeout: 5))
    }

    func testCancelledMapControlPressReleasesAndStillTaps() {
        let app = launch([])
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        let restingWidth = more.frame.width
        let start = more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let away = start.withOffset(CGVector(dx: -90, dy: 90))
        start.press(forDuration: 0.15, thenDragTo: away)
        XCTAssertTrue(more.exists, "Dragging off a control should cancel, not activate it.")
        XCTAssertEqual(more.frame.width, restingWidth, accuracy: 0.5, "The cancelled control stayed pressed.")
        more.tap()
        XCTAssertTrue(app.buttons["Close controls"].waitForExistence(timeout: 5))
    }
}
