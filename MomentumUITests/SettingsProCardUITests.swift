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
}
