import XCTest

/// Pins the goals sheet's "TODAY THAT MEANS" number to the Fuel page's own headline target: the
/// sheet used to preview the BASE target (no training burn) while the page's number included the
/// day's burn — switching goal kinds showed a number the dashboard then contradicted
/// (user report 2026-07-23).
final class FuelGoalsSheetUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func digits(_ s: String) -> Int? {
        Int(s.filter(\.isNumber))
    }

    @MainActor
    func testSheetPreviewMatchesPageHeadline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--seed-fuel-today", "--fuel"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()

        // The page's headline target: "of 1,674 kcal today" (goal) or "of 2,650+ kcal" (floor).
        let headline = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'of ' AND label CONTAINS 'kcal'")).firstMatch
        XCTAssertTrue(headline.waitForExistence(timeout: 12), "Fuel headline target not found")
        let pageTarget = try XCTUnwrap(digits(headline.label), "no number in \(headline.label)")

        app.buttons["Fueling goals"].tap()

        // The sheet's preview: "1,674" beside "kcal goal"/"kcal floor".
        let previewUnit = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'kcal '")).firstMatch
        XCTAssertTrue(previewUnit.waitForExistence(timeout: 5), "goals preview not found")
        // The number is its own Text; find the numeric static text nearest the preview block by
        // matching the exact formatted value anywhere on the sheet.
        let formatted = pageTarget.formatted()
        XCTAssertTrue(app.staticTexts[formatted].waitForExistence(timeout: 3),
                      "sheet preview does not show the page's target (\(formatted)) — the two surfaces disagree")
    }
}
