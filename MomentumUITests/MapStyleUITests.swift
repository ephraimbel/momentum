import XCTest

/// Map style consistency (decision 2026-07-09): the Strava-style picker sheet with live previews,
/// satellite as a selectable option, and — the regression that motivated it — the personal heatmap
/// keeping its heat layers when the base style changes. Dumps PNGs for visual inspection.
final class MapStyleUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
    }

    /// Today → layers button → picker sheet: every pickable style listed (satellite included),
    /// selecting one updates the persisted choice, and the sheet marks the selection.
    func testPickerOffersSatelliteAndPersistsChoice() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()

        let layers = app.buttons["Map style"]
        XCTAssertTrue(layers.waitForExistence(timeout: 20), "Layers button not on Today.")
        layers.tap()

        // The sheet lists all six styles with previews.
        XCTAssertTrue(app.staticTexts["Map style"].waitForExistence(timeout: 5), "Picker sheet didn't open.")
        // Full set, both sections ("Map" became "Light"; Dusk/Night/3D Satellite joined 2026-07-10).
        for label in ["Realistic", "Dusk", "Night", "3D Satellite", "Light", "Streets", "Outdoors", "Dark", "Satellite"] {
            XCTAssertTrue(app.buttons[label].firstMatch.exists
                          || app.buttons["\(label), selected"].firstMatch.exists,
                          "\(label) missing from picker.")
        }
        dump(app, "verify_stylepicker")

        // Realistic is the default; choose Satellite and confirm the selection sticks.
        XCTAssertTrue(app.buttons["Realistic, selected"].firstMatch.exists, "Realistic should be the default.")
        app.buttons["Satellite"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Satellite, selected"].firstMatch.waitForExistence(timeout: 3),
                      "Satellite selection didn't stick.")
        app.swipeDown(velocity: .fast)   // dismiss the sheet
        sleep(2)                          // let imagery tiles land for the dump
        dump(app, "verify_satellite_today")

        // Relaunch: the choice must survive (the original bug — style reset to the default).
        app.terminate()
        app.launchArguments = ["--seed-demo"]
        app.launch()
        XCTAssertTrue(layers.waitForExistence(timeout: 20))
        layers.tap()
        XCTAssertTrue(app.staticTexts["Map style"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Satellite, selected"].firstMatch.waitForExistence(timeout: 3),
                      "Style choice didn't persist across relaunch.")
        // Leave the app on Realistic for the athlete's next manual session.
        app.buttons["Realistic"].firstMatch.tap()
    }

    /// The heatmap keeps its heat + stats when the base style changes (the "heat areas went away" bug).
    func testHeatmapSurvivesStyleSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--progress-tab"]
        app.launch()
        app.tap()

        // Progress → History → the heatmap look-back card.
        let history = app.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 20), "History segment not found.")
        history.tap()
        let heatCard = app.staticTexts["YOUR MAP"].firstMatch
        XCTAssertTrue(heatCard.waitForExistence(timeout: 8), "Heatmap card not found in History.")
        heatCard.tap()

        // The full-screen heatmap: stats bar proves the heat data is loaded.
        let mapped = app.staticTexts["MAPPED"]
        XCTAssertTrue(mapped.waitForExistence(timeout: 15), "Heatmap didn't open with data.")
        sleep(2)
        dump(app, "verify_heatmap_before")

        // Switch the base style — the heat must re-apply on the new style.
        let layers = app.buttons["Map style"]
        XCTAssertTrue(layers.waitForExistence(timeout: 5), "Layers button missing on heatmap.")
        layers.tap()
        XCTAssertTrue(app.staticTexts["Map style"].waitForExistence(timeout: 5))
        dump(app, "verify_heatmap_sheet")
        let dark = app.buttons["Dark"].firstMatch
        if !dark.waitForExistence(timeout: 3) { app.swipeUp() }   // medium detent may clip the list
        XCTAssertTrue(dark.waitForExistence(timeout: 3), "Dark option not reachable in picker.")
        dark.tap()
        app.swipeDown(velocity: .fast)
        sleep(3)   // style load + heat re-apply + tiles
        XCTAssertTrue(mapped.exists, "Heatmap stats vanished after style switch.")
        dump(app, "verify_heatmap_after_style_switch")

        // Back to the default for the next session.
        layers.tap()
        XCTAssertTrue(app.staticTexts["Map style"].waitForExistence(timeout: 5))
        app.buttons["Realistic"].firstMatch.tap()
    }
}
