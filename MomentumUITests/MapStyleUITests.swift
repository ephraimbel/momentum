import XCTest

/// Map style consistency (decision 2026-07-09): the shared picker sheet with cached previews,
/// satellite as a selectable option, and — the regression that motivated it — the personal heatmap
/// keeping its heat layers when the base style changes. Dumps PNGs for visual inspection.
@MainActor final class MapStyleUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Today → layers button → picker sheet: every pickable style listed (satellite included),
    /// selecting one updates the persisted choice, and the sheet marks the selection.
    func testPickerOffersSatelliteAndPersistsChoice() {
        let app = XCUIApplication()
        // This test asserts the default before testing persistence. Reset the app's persisted
        // preference instead of using `-com.momentum.mapStyle realistic`: values in the launch
        // argument defaults domain override every later write, which made a valid Satellite tap
        // persist to disk while the running picker remained pinned to Realistic.
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-pro"]
        app.launch()

        // Map style lives behind the corner "More" disc on Today (2026-08-27) — open the fan first.
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 20) { more.tap() }
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
        app.launchArguments = ["--seed-demo", "--debug-pro"]
        app.launch()
        // Fresh launch, folded fan — open it again before reaching for Map style.
        let moreAgain = app.buttons["More"].firstMatch
        if moreAgain.waitForExistence(timeout: 20) { moreAgain.tap() }
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
        app.launchArguments = ["--seed-demo", "--debug-pro", "--progress-tab"]
        app.launch()
        ScrollTestSupport.dismissRecoveryIfPresent(app, timeout: 3)

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
        let sheetTitle = app.staticTexts["Map style"]
        // Dusk → Night shares a URI, while Dark replaces it: both paths must keep the heat.
        for label in ["Dusk", "Night", "Dark"] {
            layers.tap()
            XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5))
            let option = app.buttons[label].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3), "\(label) missing from picker.")
            option.tap()
            XCTAssertTrue(app.buttons["\(label), selected"].firstMatch.waitForExistence(timeout: 3))
            app.buttons["mapStyleDone"].tap()
            XCTAssertTrue(sheetTitle.waitForNonExistence(timeout: 5))
            sleep(2)   // Mapbox style load + heat re-apply + tiles, for the visual assertion
            XCTAssertTrue(mapped.exists, "Heatmap stats vanished after switching to \(label).")
            dump(app, "verify_heatmap_\(label)")
        }

        // Back to the default for the next session.
        layers.tap()
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "Picker didn't reopen for cleanup.")
        app.buttons["Realistic"].firstMatch.tap()
    }
}
