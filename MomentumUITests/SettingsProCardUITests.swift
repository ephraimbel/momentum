import XCTest

/// Verifies the Settings subscription card (Pro active under --seed-demo): the row shows the
/// app-icon brand mark + "Momentum Pro". Dumps a PNG for visual inspection.
final class SettingsProCardUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testProCardShowsAppIcon() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()

        app.buttons["Profile"].firstMatch.tap()
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Settings gear missing from Profile.")
        gear.tap()

        let pro = app.staticTexts["Momentum Pro"].firstMatch
        XCTAssertTrue(pro.waitForExistence(timeout: 10), "Pro card missing from Settings.")
        XCTAssertTrue(app.staticTexts["Active"].exists, "Pro status line missing.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_procard.png"))

        // Coach chat opens from here and carries the brand mark in its empty state.
        app.staticTexts["Open coach chat"].firstMatch.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Coach chat didn't open.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_coachchat.png"))
    }

    /// Non-US athletes can switch off miles: the Distance/Weight segmented controls select the
    /// tapped unit and persist through the profile (which the whole app reads).
    func testUnitSwitchingSelectsKilometersAndKilograms() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--settings"]
        app.launch()

        let km = app.buttons["Km distance"].firstMatch
        XCTAssertTrue(km.waitForExistence(timeout: 12), "Distance units control missing from Settings.")
        XCTAssertFalse(km.isSelected, "Km should start unselected (the demo defaults to Auto).")
        km.tap()
        XCTAssertTrue(km.isSelected, "Tapping Km did not select kilometers.")
        XCTAssertFalse(app.buttons["Auto distance"].isSelected, "Auto should deselect when Km is chosen.")

        let kg = app.buttons["Kg weight"].firstMatch
        XCTAssertTrue(kg.waitForExistence(timeout: 3), "Weight units control missing.")
        kg.tap()
        XCTAssertTrue(kg.isSelected, "Tapping Kg did not select kilograms.")
    }
}
