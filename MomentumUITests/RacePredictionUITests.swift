import XCTest

/// Verifies the R4 race-time predictor card renders on Progress → Trends for a runner (regression:
/// it was silently absent). Dumps a PNG for inspection.
final class RacePredictionUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testProjectedRacesCardShows() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--progress-tab"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()
        // Pass the sign-in gate if present.
        let guestButton = app.buttons["Continue without an account"]
        if guestButton.waitForExistence(timeout: 5) { guestButton.tap() }

        // On the Trends tab, the projected-races card sits below the coach card.
        let trends = app.buttons["Trends"]
        XCTAssertTrue(trends.waitForExistence(timeout: 20), "Progress didn't load.")
        let header = app.staticTexts["PROJECTED RACES"]
        // Scroll a little in case it's just below the fold.
        var found = header.waitForExistence(timeout: 3)
        var tries = 0
        while !found && tries < 4 { app.swipeUp(); found = header.exists; tries += 1 }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_racecard.png"))
        XCTAssertTrue(found, "Projected-races card did not render for a runner.")
        // And it should show at least one distance label.
        XCTAssertTrue(app.staticTexts["Marathon"].exists || app.staticTexts["5K"].exists,
                      "Race distances missing from the card.")
    }
}
