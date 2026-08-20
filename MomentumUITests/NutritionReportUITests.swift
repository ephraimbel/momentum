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
