import XCTest

/// Exercise interruption and rapid input while keeping the shipped welcome choreography intact.
final class WelcomeSmoothnessUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    private func launch(reduced: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--reset-auth"]
            + (reduced ? ["--ui-test-reduce-motion"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["welcome.gallery.start"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    func testRapidStartStillHandsOffOnceToAnEditableQuestion() {
        for reduced in [false, true] {
            let app = launch(reduced: reduced)
            let start = app.buttons["welcome.gallery.start"]
            capture(app, reduced ? "welcome-reduced" : "welcome-motion")
            start.doubleTap()
            let name = app.textFields["Your name"]
            XCTAssertTrue(name.waitForExistence(timeout: 10))
            XCTAssertTrue(name.isHittable)
            XCTAssertFalse(start.exists)
            name.tap(); name.typeText("Maya")
            XCTAssertEqual(name.value as? String, "Maya")
            capture(app, reduced ? "handoff-reduced" : "handoff-motion")
            app.terminate()
        }
    }

    @MainActor
    func testDragAndAccountReturnKeepButtonsStillAndUsable() {
        let app = launch()
        let start = app.buttons["welcome.gallery.start"], original = start.frame
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.27))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.58))
        from.press(forDuration: 0.1, thenDragTo: to)
        XCTAssertEqual(start.frame.minX, original.minX, accuracy: 1)
        XCTAssertEqual(start.frame.minY, original.minY, accuracy: 1)
        app.buttons["I already have an account"].tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10))
        app.buttons["Back"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isHittable)
        capture(app, "welcome-after-interruptions")
        start.tap()
        XCTAssertTrue(app.textFields["Your name"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testBackgroundImmediatelyAfterStartCannotStrandTheHandoff() {
        let app = launch()
        app.buttons["welcome.gallery.start"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertTrue(name.isHittable)
        XCTAssertFalse(app.buttons["welcome.gallery.start"].exists)
        capture(app, "handoff-after-background")
    }
}
