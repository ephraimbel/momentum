import XCTest

/// Opens a seeded run's detail (route map) to visually confirm the Mapbox route trace renders in the
/// brand purple and the map carries no Mapbox logo/attribution chrome.
final class MapboxVerifyUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testRunRouteMapTraceAndChrome() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // Progress → History → first run card → its route map.
        app.tabBars.buttons["Progress"].tap()
        let history = app.buttons["History"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10), "History segment not found.")
        history.tap()

        let run = app.buttons["Run"].firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 10), "No run card in history.")
        run.tap()

        sleep(3)   // let the Mapbox route map render its tiles + trace
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "run-route-map"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
