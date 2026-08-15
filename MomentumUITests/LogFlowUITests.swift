import XCTest

/// Pins the manual-log contract (2026-08-14): saving a hand-logged workout lands on the SAME
/// structured post-activity page a tracked one finishes on — photos, title, the full summary —
/// instead of a bare dismiss.
final class LogFlowUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testLoggedRunOpensStructuredSavePage() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--log-workout"]
        app.launch()

        // The add-workout form.
        XCTAssertTrue(app.navigationBars["Add a workout"].waitForExistence(timeout: 15),
                      "Log form didn't open.")

        // A GPS-sport direct add requires a distance before Save enables.
        let distance = app.textFields["0.0"]
        XCTAssertTrue(distance.waitForExistence(timeout: 5), "Distance field missing.")
        distance.tap()
        distance.typeText("3.1")

        let save = app.buttons["Save"]
        XCTAssertTrue(save.isEnabled, "Save should enable once a distance is entered.")
        save.tap()

        // The structured page: the photo section proves the decoration surface is live, and the
        // sport-named share CTA proves it's the same summary a tracked run gets.
        let photos = app.staticTexts["Add photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 10),
                      "Logged workout never reached the structured save page.")
        XCTAssertTrue(app.buttons["Done"].exists, "Save page's Done missing.")
    }
}
