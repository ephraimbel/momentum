import XCTest

/// The globe surface renders (docs/SOCIAL-LAYER.md, Slice 3). Uses the DEBUG `--social-globe` deep
/// link since the small toolbar globe button is unreliable to tap in the simulator.
final class GlobeUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testGlobeRenders() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route", "--social-globe"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        XCTAssertTrue(app.staticTexts["Around the world"].waitForExistence(timeout: 15),
                      "Globe header not shown.")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Momentum community'")).firstMatch.exists,
                      "Community count not shown.")
        XCTAssertTrue(app.staticTexts["Community"].exists, "Globe legend missing.")
    }
}
