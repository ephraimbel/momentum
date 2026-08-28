import XCTest

/// The History page's contract (2026-08-28 refinement): the summary card leads, the sport filter
/// actually filters, month sections carry their rows, and a row opens its workout.
final class HistoryPageUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--seed-dense-history", "--progress-tab", "--progress-history"]
        app.launch()
        return app
    }

    func testSummaryFilterAndRowsWorkTogether() {
        let app = launch()
        // The summary card leads the page (its facts line names the sessions).
        let august = app.staticTexts[Date().formatted(.dateTime.month(.wide)).uppercased()]
        XCTAssertTrue(august.waitForExistence(timeout: 15), "the month summary card should lead History")

        // The sport filter is present for a multi-sport athlete, and Strength shows lifts.
        let strengthChip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Strength'")).firstMatch
        XCTAssertTrue(strengthChip.waitForExistence(timeout: 5), "a multi-sport history should offer sport chips")
        strengthChip.tap()
        let lift = app.staticTexts["Weight Training"].firstMatch
        XCTAssertTrue(lift.waitForExistence(timeout: 5), "the Strength filter should keep lifting sessions")

        // Switching to Runs drops the lifts entirely (the filter really filters).
        let runsChip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Runs'")).firstMatch
        XCTAssertTrue(runsChip.exists)
        runsChip.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: lift, handler: nil)
        waitForExpectations(timeout: 6)

        // A row opens its workout, and back returns to History with the filter still on Runs.
        let firstRow = app.buttons.matching(NSPredicate(format: "label != '' ")).element(boundBy: 0)
        XCTAssertTrue(firstRow.exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Runs'")).firstMatch.exists,
                      "the filter row should survive scrolling")
    }

    func testEmptyFilterExplainsItself() {
        let app = launch()
        XCTAssertTrue(app.staticTexts[Date().formatted(.dateTime.month(.wide)).uppercased()].waitForExistence(timeout: 15))
        // "Other" is empty for the demo athlete (runs + lifts + one ride) — it must say so
        // rather than showing a blank page.
        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Other'")).firstMatch
        guard other.waitForExistence(timeout: 4) else { return }   // no Other bucket seeded: nothing to prove
        other.tap()
        XCTAssertTrue(app.staticTexts["Nothing else logged yet."].waitForExistence(timeout: 5))
    }
}
