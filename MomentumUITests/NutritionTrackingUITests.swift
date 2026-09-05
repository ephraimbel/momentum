import XCTest

final class NutritionTrackingUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--reset-fuel", "--debug-pro", "--fuel",
                               "-com.momentum.review.rated.v2", "YES", "-com.momentum.fuel.siriTip", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["fuel-manual-entry"].waitForExistence(timeout: 25))
        return app
    }

    private func field(_ id: String, in app: XCUIApplication) -> XCUIElement { app.textFields[id] }

    private func daily(_ nutrient: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["daily-\(nutrient)"].firstMatch
    }

    private func enter(_ text: String, id: String, in app: XCUIApplication) {
        let input = field(id, in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 4), "Missing \(id)")
        for _ in 0..<6 {
            // XCTest can report a field beneath the keyboard accessory as hittable.
            // Bring the entire input above Done before tapping, as a person would scroll.
            let done = app.toolbars.buttons["Done"].firstMatch
            let bottom = done.exists ? done.frame.minY - 12 : app.frame.maxY - 50
            if input.isHittable && input.frame.maxY < bottom { break }
            // Start within the visible form; a full-screen swipe starts on the keyboard.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)))
        }
        input.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { input.tap() }
        input.typeText(text)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testManualEntryWaterAndPersistentDailyTotals() {
        let app = launch()
        shot(app, "fuel-empty-actions")
        app.buttons["fuel-manual-entry"].tap()
        XCTAssertTrue(app.navigationBars["Add nutrition"].waitForExistence(timeout: 5))
        let name = app.descendants(matching: .any)["meal-name"].firstMatch
        name.tap(); name.typeText("Recovery lunch")
        enter("80", id: "nutrition-carbs", in: app)
        enter("650", id: "nutrition-kcal", in: app)
        enter("35", id: "nutrition-protein", in: app)
        enter("18", id: "nutrition-fat", in: app)
        enter("700", id: "nutrition-sodium", in: app)
        enter("400", id: "nutrition-fluids", in: app)
        app.toolbars.buttons["Done"].tap()
        let details = app.buttons["meal-more-nutrients"]
        for _ in 0..<5 where !details.isHittable { app.swipeUp() }
        details.tap()
        enter("8", id: "nutrition-fiber", in: app)
        enter("12", id: "nutrition-sugar", in: app)
        enter("4", id: "nutrition-saturatedFat", in: app)
        enter("800", id: "nutrition-potassium", in: app)
        enter("120", id: "nutrition-magnesium", in: app)
        enter("2.7", id: "nutrition-iron", in: app)
        enter("300", id: "nutrition-calcium", in: app)
        shot(app, "manual-nutrition-all-fields")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 5))
        for _ in 0..<5 where !app.buttons["fuel-water-250"].isHittable { app.swipeDown() }
        app.buttons["fuel-water-250"].tap()
        XCTAssertFalse(app.buttons["Meal: Water, 250 ml"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Log again: Water'")).firstMatch.exists)
        app.buttons["fuel-daily-nutrition"].tap()
        XCTAssertTrue(app.navigationBars["Daily nutrition"].waitForExistence(timeout: 5))
        XCTAssertTrue(daily("kcal", in: app).waitForExistence(timeout: 4))
        XCTAssertTrue(daily("kcal", in: app).label.contains("650 kcal"))
        XCTAssertTrue(daily("fiber", in: app).label.contains("8 g"))
        shot(app, "daily-nutrition-macros")
        for _ in 0..<5 where !daily("fluids", in: app).isHittable { app.swipeUp() }
        XCTAssertTrue(daily("fluids", in: app).label.contains("650 ml"))
        XCTAssertTrue(daily("iron", in: app).label.contains("2.7 mg"))
        XCTAssertFalse(daily("fluids", in: app).label.contains("Partial"))
        shot(app, "daily-nutrition-minerals-coverage")
        app.terminate()
        app.launchArguments = ["--debug-pro", "--fuel", "-com.momentum.review.rated.v2", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["fuel-daily-nutrition"].waitForExistence(timeout: 20))
        app.buttons["fuel-daily-nutrition"].tap()
        XCTAssertTrue(daily("kcal", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(daily("kcal", in: app).label.contains("650 kcal"))
    }

    func testCancelAndInvalidInputDoNotCreateEntries() {
        let app = launch()
        app.buttons["fuel-manual-entry"].tap()
        XCTAssertTrue(app.navigationBars["Add nutrition"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons["Save"].isEnabled)
        let name = app.descendants(matching: .any)["meal-name"].firstMatch
        name.tap(); name.typeText("Unsaved meal")
        enter("-5", id: "nutrition-kcal", in: app)
        XCTAssertFalse(app.navigationBars.buttons["Save"].isEnabled)
        app.navigationBars.buttons["Cancel"].tap()
        app.buttons["fuel-daily-nutrition"].tap()
        XCTAssertTrue(app.staticTexts["No meals recorded for this day."].waitForExistence(timeout: 5))
    }

    func testWaterStaysInHydrationAndCanBeRemoved() {
        let app = launch()
        app.buttons["fuel-water-250"].tap()
        app.buttons["fuel-water-log"].tap()
        XCTAssertTrue(app.navigationBars["Water"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["water-total"].label.contains("250"))
        shot(app, "water-own-section")
        app.buttons["Delete 250 milliliters of water"].tap()
        XCTAssertTrue(app.staticTexts["No water logged for this day."].waitForExistence(timeout: 4))
        app.navigationBars.buttons["Done"].tap()
        app.buttons["fuel-daily-nutrition"].tap()
        XCTAssertTrue(app.staticTexts["No meals recorded for this day."].waitForExistence(timeout: 5))
    }
}
