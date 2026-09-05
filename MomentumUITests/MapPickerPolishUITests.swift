import XCTest

/// Shared picker contract: immediate selection, persistence, nested Pro handoff, stable dismissal,
/// and usable controls even when thumbnails cannot load. These tests never record/discard a run.
@MainActor final class MapPickerPolishUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(_ extra: [String] = [], pro: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--awards-quiet", "--today-sport", "run",
                               "--today-rail-open", "--map-picker", pro ? "--debug-pro" : "--debug-free"] + extra
        app.launch()
        ScrollTestSupport.dismissRecoveryIfPresent(app, timeout: 3)
        XCTAssertTrue(app.buttons["mapStyleDone"].waitForExistence(timeout: 20))
        return app
    }

    private func pick(_ raw: String, in app: XCUIApplication) {
        let cell = app.buttons["mapStyle.\(raw)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        let scroll = app.scrollViews["mapStyleOptions"]
        for _ in 0..<6 where !cell.isHittable {
            if cell.frame.midY < scroll.frame.midY { scroll.swipeDown() }
            else { scroll.swipeUp() }
        }
        XCTAssertTrue(cell.isHittable, "\(raw) must be reachable")
        cell.tap()
    }

    private func assertSelected(_ raw: String, in app: XCUIApplication) {
        let cell = app.buttons["mapStyle.\(raw)"]
        XCTAssertTrue(NSPredicate(format: "selected == true").evaluate(with: cell), "\(raw) was not selected")
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mapStyle.' AND selected == true"))
        XCTAssertEqual(selected.count, 1, "Exactly one map style should be selected")
    }

    func testEveryStyleAppliesAndLastChoiceSurvivesRelaunch() {
        let app = launch()
        for raw in ["realistic", "dusk", "night", "standardSatellite", "standard", "streets", "outdoors", "dark", "satellite"] {
            pick(raw, in: app)
            assertSelected(raw, in: app)
        }
        attach(app, "map-picker-all-styles")
        app.buttons["mapStyleDone"].tap()
        XCTAssertTrue(app.buttons["mapStyleDone"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Today"].isHittable)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["mapStyleDone"].waitForExistence(timeout: 20))
        assertSelected("satellite", in: app)
        pick("realistic", in: app)
        app.buttons["mapStyleDone"].tap()
    }

    func testLockedStylePresentsAbovePickerAndReturnsWithoutChangingSelection() {
        let app = launch(pro: false)
        pick("standard", in: app)
        assertSelected("standard", in: app)
        for _ in 0..<2 {
            pick("dusk", in: app)
            let close = app.buttons["Close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 8), "The Pro screen must present above the picker")
            attach(app, "map-picker-pro-handoff")
            close.tap()
            XCTAssertTrue(app.buttons["mapStyleDone"].waitForExistence(timeout: 8))
            assertSelected("standard", in: app)
        }
        app.buttons["mapStyleDone"].tap()
        XCTAssertTrue(app.buttons["mapStyleDone"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Today"].isHittable)
    }

    func testUnavailablePreviewsStillAllowSelectionDismissalAndReopening() {
        let app = launch(["--ui-test-map-preview-unavailable", "--ui-test-reduce-motion"])
        for _ in 0..<3 {
            pick("standard", in: app)
            assertSelected("standard", in: app)
            app.buttons["mapStyleDone"].tap()
            XCTAssertTrue(app.buttons["mapStyleDone"].waitForNonExistence(timeout: 5))
            app.buttons["Map style"].tap()
            XCTAssertTrue(app.buttons["mapStyleDone"].waitForExistence(timeout: 5))
        }
        attach(app, "map-picker-unavailable-previews")
        pick("realistic", in: app)
        app.buttons["mapStyleDone"].tap()
    }

    func testDarkAppearanceKeepsExplicitLightChoice() {
        let app = launch(["-com.momentum.appearance", "dark"])
        pick("standard", in: app)
        assertSelected("standard", in: app)
        attach(app, "map-picker-dark")
        app.buttons["mapStyleDone"].tap()
        XCTAssertTrue(app.buttons["mapStyleDone"].waitForNonExistence(timeout: 5))
        app.buttons["Map style"].tap()
        XCTAssertTrue(app.buttons["mapStyleDone"].waitForExistence(timeout: 5))
        assertSelected("standard", in: app)
        pick("realistic", in: app)
    }

    func testAccessibilityTextSizeKeepsDoneAndLastStyleReachable() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["mapStyleDone"].isHittable)
        pick("satellite", in: app)
        assertSelected("satellite", in: app)
        XCTAssertTrue(app.buttons["mapStyleDone"].isHittable, "Done must stay reachable while scrolling")
        attach(app, "map-picker-accessibility-type")
        pick("realistic", in: app)
        app.buttons["mapStyleDone"].tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
