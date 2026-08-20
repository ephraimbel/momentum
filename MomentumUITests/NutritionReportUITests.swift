import XCTest

/// The Nutrition report (2026-08-20): the health-score page grown into the month view. Walks the
/// whole page on seeded 4-month history and pins every section — hero, drivers, today's ranked
/// food, the 30-day score and energy charts, floor consistency, processed share, recurring
/// staples, and the monthly minerals — attaching a screenshot at each stop.
final class NutritionReportUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = true }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Swipe until the element exists on screen (sections live below the fold on every device).
    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists
    }

    /// The one-page-tracker pass (2026-08-20): the journal files itself into meal-time chapters,
    /// and a logged meal can grow an item from the offline pantry — instant, free, and the Σ
    /// footer + score roll live.
    func testDaypartsAndAddItem() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-fuel", "--seed-demo", "--seed-fuel-today",
                               "--debug-pro", "--fuel", "--meal-detail"]
        app.launch()

        // The detail sheet opens on the newest seeded meal (an evening one) — add a pantry item.
        let addField = app.textFields["Add an item — banana, 2 eggs…"]
        XCTAssertTrue(addField.waitForExistence(timeout: 20), "Add-an-item field missing from the sheet.")
        addField.tap()
        addField.typeText("banana\n")
        XCTAssertTrue(app.staticTexts["Banana"].waitForExistence(timeout: 4),
                      "The pantry item didn't join the meal's item list.")
        attach(app, "6-item-added")
        app.buttons["Save"].tap()

        // Back on the page: the journal reads in meal-time chapters with kcal sums.
        XCTAssertTrue(app.staticTexts["TODAY"].waitForExistence(timeout: 8), "Journal missing.")
        let chapters = ["MORNING", "MIDDAY", "EVENING"]
        var found = 0
        for label in chapters where app.staticTexts[label].exists { found += 1 }
        if found < 2 { app.swipeUp(); for label in chapters where app.staticTexts[label].exists { found += 1 } }
        XCTAssertTrue(found >= 2, "Daypart chapters missing — the seeded day spans morning to evening.")
        attach(app, "7-dayparts")
    }

    func testMonthReportSectionsRender() {
        let app = XCUIApplication()
        // --reset-fuel first: earlier containers carry pre-NOVA seeds; the wipe lets the seeds
        // re-run in their itemized form so the processed-share gate has data (hermetic, the
        // FuelFlowUITests pattern).
        app.launchArguments = ["--reset-fuel", "--seed-demo", "--seed-fuel-history", "--seed-fuel-today",
                               "--debug-pro", "--fuel", "--fuel-health"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Nutrition"].waitForExistence(timeout: 20),
                      "The Nutrition page didn't open from --fuel-health.")
        XCTAssertTrue(app.staticTexts["WHAT SHAPED IT"].waitForExistence(timeout: 8),
                      "Drivers section missing — the seeded day carries quality fields.")
        attach(app, "1-hero-and-drivers")

        XCTAssertTrue(scrollTo(app.staticTexts["TODAY'S FOOD, RANKED"], in: app),
                      "Ranked section missing.")
        XCTAssertTrue(scrollTo(app.staticTexts["THE LAST 30 DAYS"], in: app),
                      "30-day score section missing — 4 months of seeds should fill it.")
        attach(app, "2-score-month")

        XCTAssertTrue(scrollTo(app.staticTexts["ENERGY"], in: app), "Energy section missing.")
        XCTAssertTrue(scrollTo(app.staticTexts["FLOORS HIT"], in: app), "Floors section missing.")
        attach(app, "3-energy-and-floors")

        XCTAssertTrue(scrollTo(app.staticTexts["PROCESSED SHARE"], in: app),
                      "Processed-share section missing — the seeds include gel days every week.")
        XCTAssertTrue(scrollTo(app.staticTexts["YOUR STAPLES THIS MONTH"], in: app),
                      "Staples section missing.")
        attach(app, "4-processed-and-staples")

        XCTAssertTrue(scrollTo(app.staticTexts["MINERALS THIS MONTH"], in: app),
                      "Minerals section missing — seeds carry all four micros.")
        // The labels render whole — the old three-column row squeezed "Potassium" into a clipped
        // tail (owner report 2026-08-20); the stacked cell owns its full line.
        XCTAssertTrue(app.staticTexts["Potassium"].exists, "Potassium label missing or clipped.")
        XCTAssertTrue(app.staticTexts["Magnesium"].exists, "Magnesium label missing or clipped.")
        attach(app, "5-minerals")
    }
}
