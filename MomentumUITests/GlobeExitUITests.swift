import XCTest

/// The globe's "Back to Today" control returns to the Today map. Regression guard: a plain SwiftUI
/// button loses the gesture race against the live Mapbox map, so the control uses a highPriorityGesture
/// — this verifies the tap actually fires and Today comes back. Uses the deterministic `--world` entry.
final class GlobeExitUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testBackToTodayFromGlobe() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--world"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Around the world"].waitForExistence(timeout: 15), "Globe didn't open.")
        sleep(4)   // let the fly-out settle

        let back = app.buttons["Back to Today"]
        XCTAssertTrue(back.exists, "Back control missing on the globe.")
        back.tap()

        let started = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Start'")).firstMatch.waitForExistence(timeout: 10)
        XCTAssertTrue(started, "Start control didn't return — didn't go back to Today.")
        XCTAssertFalse(app.staticTexts["Around the world"].exists, "Still on the globe after tapping back.")
    }
}
