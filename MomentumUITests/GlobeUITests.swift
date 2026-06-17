import XCTest

/// The World tab IS the globe (docs/SOCIAL-LAYER.md) — no feed. Tapping World renders the Mapbox
/// globe with the community count + legend; honest presence only (real community + you).
final class GlobeUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testWorldTabIsGlobe() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route", "--reset-social"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        let world = app.tabBars.buttons["World"]
        XCTAssertTrue(world.waitForExistence(timeout: 15), "World tab not found.")
        world.tap()

        XCTAssertTrue(app.staticTexts["Around the world"].waitForExistence(timeout: 10),
                      "Globe header not shown — World tab should be the globe.")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Momentum community'")).firstMatch.exists,
                      "Community count not shown.")
        XCTAssertTrue(app.staticTexts["Community"].exists, "Globe legend missing.")
    }
}
