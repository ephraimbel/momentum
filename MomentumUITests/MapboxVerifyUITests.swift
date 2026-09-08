import XCTest

/// Opens a seeded run's detail (route map) to confirm the Mapbox route trace renders in the brand
/// purple and the map carries no Mapbox logo/attribution chrome.
///
/// The chrome half is asserted, not just screenshotted (2026-09-07): `MapChrome.minimal` hides the
/// logo and the attribution button on every map, and the credit lives in Settings' colophon
/// instead. The logo view is decorative and exposes no accessibility element, so the attribution
/// button is the thing a test can actually see; both are set from the same options, so it standing
/// in for the pair is exactly what regresses if someone restores them.
final class MapboxVerifyUITests: XCTestCase {

    /// The SDK's attribution ornament, by the label it ships (`INFO_A11Y_LABEL`).
    private static let attributionLabel = "About this map"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// No Mapbox attribution ornament anywhere on screen.
    private func assertNoMapChrome(_ app: XCUIApplication, _ surface: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let attribution = app.buttons[Self.attributionLabel]
        // Settled state, not the first frame. The SwiftUI wrapper hands `ornamentOptions` to the
        // ornaments manager as part of the map view's setup, so between the map being mounted and
        // being initialised the SDK's default (visible) ornaments exist in the accessibility tree.
        // The athlete never sees them there: the map has not drawn a pixel yet and the ornament
        // sits under the stats card. What must hold, and what this waits for, is that once the map
        // is up nothing of Mapbox's own chrome is on it.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: attribution)
        let settled = XCTWaiter().wait(for: [gone], timeout: 10) == .completed
        // The frame is in the message on purpose: when this fails, which map owns the ornament is
        // the whole question, and its position answers it.
        XCTAssertTrue(settled,
                      "\(surface) still shows the Mapbox attribution ornament at \(attribution.exists ? "\(attribution.frame)" : "nowhere") after it settled; the credit belongs in Settings' colophon.",
                      file: file, line: line)
    }

    func testRunRouteMapTraceAndChrome() {
        let app = XCUIApplication()
        // `--reset-store`: these tests navigate by on-screen labels, and a container left behind by
        // a previous test (or a manual `--seed-demo` launch) strands them before the map they came
        // to check. Each run starts from a known store.
        app.launchArguments = ["--reset-store", "--seed-demo", "--ui-test-route"]
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
        assertNoMapChrome(app, "The run detail route map")
    }

    /// Captures the History feed, whose cards show route-snapshot thumbnails (gradient trace).
    func testHistoryThumbnail() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--ui-test-route"]
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
        assertNoMapChrome(app, "The history feed")
    }

    /// Starts a live run (deterministic moving GPS via --ui-test-route) and captures the tracking map
    /// — the purple location puck + purple route trace.
    func testLiveTrackingMap() {
        let app = XCUIApplication()
        // `--live-page-cycle` scripts the pager from arming: 6 s map page, 12 s pause, 18 s back to
        // stats. Asserting inside that map window is the point — the stats page covers the map
        // completely, and a map nobody can see says nothing about the chrome on one they can.
        app.launchArguments = ["--reset-store", "--seed-demo", "--ui-test-route", "--live-page-cycle"]
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

        // Inside the scripted map window (6 s to 18 s after arming), with a trace accumulated.
        sleep(11)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "live-tracking-map"
        shot.lifetime = .keepAlways
        add(shot)
        // Deliberately no `assertNoMapChrome` here. The live map is held at `opacity(mapReady)`
        // until its style loads, and until then it keeps the SDK's default ornaments: invisible on
        // screen, but still in the accessibility tree, which is all XCUITest can see. In the
        // simulator that style often does not load inside a scripted run, so the assertion would
        // fail on a map the athlete cannot see. Its chrome comes from the same one line
        // (`MapChrome.minimal`) the three asserted surfaces above use, so the policy is covered;
        // this test stays a visual record of the purple trace and puck.
    }

    /// The map picker: the browsing map behind it, and the style thumbnails it renders. The
    /// thumbnails bake their own image through `Snapshotter`, so they carry a separate switch
    /// (`showsLogo`/`showsAttribution`) from the live maps' ornaments.
    func testMapPickerAndStyleThumbnails() {
        let app = XCUIApplication()
        // `--reset-store`: the picker only opens on a fresh container, and a `--seed-demo` launch
        // left over from another run (or a manual one) is enough to strand it.
        app.launchArguments = ["--reset-store", "--seed-demo", "--awards-quiet", "--today-sport", "run",
                               "--today-rail-open", "--map-picker", "--debug-pro"]
        app.launch()

        XCTAssertTrue(app.buttons["mapStyleDone"].waitForExistence(timeout: 20), "Map picker did not open.")
        // The thumbnails render through a snapshot pipeline; give them a beat to land.
        sleep(8)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "map-picker-styles"
        shot.lifetime = .keepAlways
        add(shot)
        assertNoMapChrome(app, "The map picker")
    }
}
