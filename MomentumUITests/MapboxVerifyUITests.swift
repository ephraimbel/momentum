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

    /// Captures the History feed, whose cards show route-snapshot thumbnails (gradient trace).
    func testHistoryThumbnail() {
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

        app.tabBars.buttons["Progress"].tap()
        let history = app.buttons["History"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10), "History segment not found.")
        history.tap()
        XCTAssertTrue(app.buttons["Run"].firstMatch.waitForExistence(timeout: 10), "No run card in history.")

        sleep(2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "history-thumbnails"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Starts a live run (deterministic moving GPS via --ui-test-route) and captures the tracking map
    /// — the purple location puck + purple route trace.
    func testLiveTrackingMap() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // Ensure Run mode, then start.
        let startRun = app.buttons["Start run"]
        if !startRun.waitForExistence(timeout: 10) {
            app.buttons["Run"].firstMatch.tap()
            app.buttons["Run"].firstMatch.tap()
        }
        XCTAssertTrue(startRun.waitForExistence(timeout: 10), "Could not find 'Start run'.")
        startRun.tap()

        // Reach the tracking screen (skip the acquiring gate via "Start now" if needed).
        let pause = app.buttons["Pause"]
        let startNow = app.buttons["Start now"]
        let deadline = Date().addingTimeInterval(25)
        while !pause.exists && Date() < deadline {
            if startNow.exists && startNow.isHittable { startNow.tap() }
            usleep(300_000)
        }
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Live tracking did not begin.")

        sleep(26)   // let a real trace accumulate so the gradient is visible
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "live-tracking-map"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
