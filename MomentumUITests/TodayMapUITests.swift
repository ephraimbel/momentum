import XCTest

/// The Today map essentials (PRD §4.2/§7.2): the loop suggester is reachable from the start card, and
/// the recenter control exists. Location is pre-granted + set via `simctl` by the run script, so the
/// puck and "Loop"/"Spots" buttons are present.
final class TodayMapUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testSuggestLoopReachableFromToday() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()   // clear any location prompt via the monitor

        // The recenter control and the loop entry are both on Today.
        XCTAssertTrue(app.buttons["Recenter on my location"].waitForExistence(timeout: 15),
                      "Recenter arrow missing from Today.")
        let loop = app.buttons["Suggest a running loop"]   // the Loop chip's VoiceOver label
        XCTAssertTrue(loop.waitForExistence(timeout: 10),
                      "Loop (suggest a loop) chip not shown on Today.")

        // Tapping it opens the loop suggester at the athlete's location.
        loop.tap()
        let opened = app.buttons["5K"].waitForExistence(timeout: 12) || app.staticTexts["5K"].exists
        XCTAssertTrue(opened, "'Loop' didn't open the loop suggester.")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "today-suggested-loop"; shot.lifetime = .keepAlways
        add(shot)
    }

    /// The redesigned start card: compact goal segmented control + Distance stepper layout holds.
    func testGoalDistanceLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()
        app.tap()

        let distance = app.buttons["Distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 15), "Goal 'Distance' segment missing.")
        distance.tap()
        XCTAssertTrue(app.buttons["Start run"].waitForExistence(timeout: 5), "Start button missing after Distance.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "today-goal-distance"; shot.lifetime = .keepAlways
        add(shot)
    }
}
