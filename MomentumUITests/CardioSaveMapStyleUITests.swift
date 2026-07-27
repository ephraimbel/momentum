import XCTest

/// The post-run save screen's map-style moment (user ask 2026-07-11): finish a run → the editor
/// offers per-run map styles; free styles apply, Pro styles open the paywall for a free athlete;
/// the photo section is editable at save. Runs the same self-contained `--ui-test-route` flow as
/// RunPauseUITests, so no permission alert or flaky sim GPS is involved.
final class CardioSaveMapStyleUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testSaveScreenOffersMapStylesAndGatesProOnes() {
        let app = XCUIApplication()
        // `--save-screen` opens the save editor for the newest seeded GPS run directly — driving a
        // live run's Finish through XCUITest proved flaky (transparent controls over the map), and
        // the editor is what this test is about.
        app.launchArguments = ["--seed-demo", "--debug-free", "--save-screen"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        // "Done", not "Save": the confirm action was renamed with the screen's title (the recording
        // is already on disk by the time this appears). This assertion still said "Save", so the
        // whole map-style guard had been failing on its first line.
        let saveButton = app.buttons["Done"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 20), "Save screen didn't open.")

        // The map-style row: free styles + Pro styles present.
        app.swipeUp(); app.swipeUp()
        let mapStyleLabel = app.staticTexts["Map style"]
        XCTAssertTrue(mapStyleLabel.waitForExistence(timeout: 5), "Map style row missing from the save editor.")
        XCTAssertTrue(app.buttons["Light"].exists, "Free style chip missing.")

        // Free chip applies (stays on the save screen).
        app.buttons["Light"].tap()
        XCTAssertTrue(saveButton.exists, "Applying a free style should not leave the save screen.")

        // Pro chip → paywall for a free athlete (the upgrade moment), then close it.
        let proChip = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Pro style'")).firstMatch
        XCTAssertTrue(proChip.exists, "Pro style chips missing.")
        proChip.tap()
        let trialCTA = app.buttons["Start my 7-day free trial"]
        XCTAssertTrue(trialCTA.waitForExistence(timeout: 8), "Pro style did not open the paywall.")
        attach(app, name: "save-mapstyle-paywall")
        app.buttons["Close"].firstMatch.tap()

        // Photos are editable at save (camera/library entry point exists).
        XCTAssertTrue(app.buttons["Add photos"].waitForExistence(timeout: 5) || app.buttons["Add photo"].exists,
                      "Photo add entry point missing from the save screen.")
        attach(app, name: "save-mapstyle-row")

        // Save completes the flow: the celebration auto-dismisses too fast for a reliable text
        // assert, so completion = the editor going away.
        app.buttons["Done"].tap()
        XCTAssertTrue(saveButton.waitForNonExistence(timeout: 15), "Save didn't complete.")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
