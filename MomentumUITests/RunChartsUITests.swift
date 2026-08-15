import XCTest

/// Verifies the post-run analysis charts (R2): open a seeded run's detail and confirm the pace /
/// splits / elevation charts render. Dumps a PNG for visual inspection.
final class RunChartsUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
    }

    func testRunDetailShowsCharts() {
        let app = XCUIApplication()
        // The run-detail deep link opens a seeded run directly — History's feed rows carry composed
        // accessibility labels (post-lean-cleanup), so navigating by an exact "Run" label is brittle.
        app.launchArguments = ["--seed-demo", "--ui-test-run-detail"]
        app.launch()

        // The detail scrolls; charts live below the route map. Swipe up to reveal them.
        let splits = app.staticTexts["SPLITS"]
        XCTAssertTrue(splits.waitForExistence(timeout: 15), "Run detail didn't open.")

        // PACE and ELEVATION only — never "SPLITS". That string is BOTH a chart title and the
        // header of the plain splits list below, and it was already asserted above as the
        // "detail opened" guard, so `|| splits.exists` made this assertion unfailable. It passed
        // green for weeks while `RunAnalysisSection` rendered nothing at all (its `.task` hung off
        // a view that starts empty, so it never fired). A chart test must name a chart.
        let pace = app.staticTexts["PACE"], elevation = app.staticTexts["ELEVATION"]
        let deadline = Date().addingTimeInterval(10)
        while !pace.exists, !elevation.exists, Date() < deadline { app.swipeUp(); usleep(300_000) }
        dump(app, "verify_runcharts")
        XCTAssertTrue(pace.exists, "Pace chart missing from run detail.")
        XCTAssertTrue(elevation.exists, "Elevation chart missing from run detail.")
    }

    /// The hero map's tap-through (2026-08-13): tap → full-screen explorable map, X → back to
    /// the summary. Tap with a retry — taps over a Mapbox canvas can drop once basemap tiles
    /// land (the map-chrome tap race), and a single dropped tap must not fail the CONTRACT.
    func testMapExpandsFullScreenAndCloses() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-run-detail"]
        app.launch()

        let hero = app.descendants(matching: .any)["Route map. Opens full screen."].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 15), "Summary map hero missing.")

        let close = app.buttons["Close map"]
        for _ in 0..<3 where !close.exists {
            hero.tap()
            _ = close.waitForExistence(timeout: 4)
        }
        dump(app, "verify_fullmap_open")
        XCTAssertTrue(close.exists, "Tapping the map never opened the full-screen map.")

        close.tap()
        let goneByDeadline = Date().addingTimeInterval(6)
        while close.exists, Date() < goneByDeadline { usleep(200_000) }
        dump(app, "verify_fullmap_closed")
        XCTAssertFalse(close.exists, "Close didn't dismiss the full-screen map.")
        XCTAssertTrue(hero.waitForExistence(timeout: 6), "Summary didn't return after closing the map.")
    }
}
