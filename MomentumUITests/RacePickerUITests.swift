import XCTest

/// Drives the race picker the way an athlete would (2026-07-11 flow: select → review → lock in).
/// Proves the whole UX live: nothing commits on first tap, the review opens in place, the pinned
/// lock-in bar does the committing, and the picked race lands back in plan settings — name filled,
/// rebuild armed. Also exercises search + a weekend sub-distance.
final class RacePickerUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launchToPicker() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--plan-tab", "--plan-settings", "--race-picker"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()
        return app
    }

    func testSelectReviewLockInFlow() {
        let app = launchToPicker()

        // The catalog opens with the majors spotlighted.
        let boston = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Boston Marathon'")).firstMatch
        XCTAssertTrue(boston.waitForExistence(timeout: 15), "Race picker didn't open with Boston visible.")

        // First tap SELECTS — the review opens in place, nothing commits yet.
        boston.tap()
        let lockIn = app.buttons["Lock in Boston Marathon"]
        XCTAssertTrue(lockIn.waitForExistence(timeout: 5), "Selecting Boston didn't reveal the lock-in bar.")
        XCTAssertTrue(app.buttons["Marathon"].firstMatch.exists, "The distance chip should be visible in review.")

        // Second tap on the card CLOSES the review — browsing is always safe.
        boston.tap()
        XCTAssertFalse(app.buttons["Lock in Boston Marathon"].waitForExistence(timeout: 2),
                       "Re-tapping the card should close the review, not commit.")

        // Reopen and commit deliberately.
        boston.tap()
        XCTAssertTrue(lockIn.waitForExistence(timeout: 5))
        lockIn.tap()

        // Back in plan settings: the race is locked in — name filled, structural rebuild armed.
        XCTAssertTrue(app.buttons["Rebuild plan"].waitForExistence(timeout: 5),
                      "Locking in a race should arm the structural rebuild.")
        XCTAssertTrue(app.textFields["Boston Marathon"].exists
                      || app.textFields.matching(NSPredicate(format: "value == 'Boston Marathon'")).firstMatch.exists,
                      "The plan name should carry the race.")
    }

    func testSearchAndWeekendSubDistance() {
        let app = launchToPicker()

        // Search narrows to Disney; its weekend offers four distances.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("Disney")

        let disney = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Walt Disney World Marathon'")).firstMatch
        XCTAssertTrue(disney.waitForExistence(timeout: 5), "Search didn't surface Disney.")
        disney.tap()

        // Pick the half from the weekend's chips, then lock it in.
        let half = app.buttons["Half marathon"]
        XCTAssertTrue(half.waitForExistence(timeout: 5), "Weekend sub-distances didn't appear.")
        half.tap()
        let lockIn = app.buttons["Lock in Walt Disney World Marathon"]
        XCTAssertTrue(lockIn.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Half marathon ·'")).firstMatch.exists,
                      "The lock-in bar should restate the chosen distance.")
        lockIn.tap()

        XCTAssertTrue(app.buttons["Rebuild plan"].waitForExistence(timeout: 5),
                      "Locking in the Disney half should arm the rebuild.")
    }
}
