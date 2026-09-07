import XCTest

/// The plan lifecycle flows (2026-07-12): goals change, so the Plan page offers two first-class
/// intents — adjust the current plan, or start a completely new one. This drives the new-plan flow
/// live: fresh form, blank name, "Create plan" commits a full rebuild and lands back on the page.
final class PlanFlowsUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func testStartANewPlanFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--plan-tab", "--plan-new"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()

        // The creation frame: its own title and a blank name, but no silently inherited objective.
        XCTAssertTrue(app.navigationBars["New plan"].waitForExistence(timeout: 15),
                      "Start-a-new-plan should open its own framed sheet.")
        let create = app.buttons["Create plan"]
        XCTAssertTrue(create.exists, "The new-plan flow must always offer Create plan.")
        XCTAssertEqual(create.value as? String, "Choose a goal",
                       "A new plan must wait for an explicit goal choice.")
        let nameField = app.textFields["e.g. Austin Marathon"]
        XCTAssertTrue(nameField.exists,
                      "A new plan starts with a blank name — its own occasion.")
        let goalHeader = app.staticTexts["YOUR GOAL"]
        XCTAssertTrue(goalHeader.exists)
        XCTAssertLessThan(nameField.frame.minY, goalHeader.frame.minY,
                          "Plan name belongs at the top of both plan forms.")

        // A race is not a complete goal until its distance is explicit; switching to a complete
        // open-ended goal arms creation immediately.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run a race'"))
            .firstMatch.tap()
        XCTAssertEqual(create.value as? String, "Choose a race distance",
                       "A race plan must wait for a race distance.")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run farther & faster'"))
            .firstMatch.tap()
        XCTAssertEqual(create.value as? String, "Ready to create",
                       "Choosing a complete goal should arm plan creation.")
        create.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH 'Run farther & faster · Week 1 of'"
        )).firstMatch.waitForExistence(timeout: 10)
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Week 1'")).firstMatch.waitForExistence(timeout: 10),
                      "Creating should land back on the Plan page with a fresh week one.")
    }

    @MainActor
    func testAdjustPlanKeepsExistingNameAboveGoal() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store", "--seed-demo", "--seed-plan-name", "--plan-tab", "--plan-settings",
        ]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        XCTAssertTrue(app.navigationBars["Plan settings"].waitForExistence(timeout: 15),
                      "Adjusting should open the existing-plan form.")
        let nameField = app.textFields["e.g. Austin Marathon"]
        let goalHeader = app.staticTexts["YOUR GOAL"]
        XCTAssertTrue(nameField.exists, "Adjusting must keep the editable plan name visible.")
        XCTAssertFalse((nameField.value as? String ?? "").isEmpty,
                       "Adjusting must prefill the athlete's existing plan name.")
        XCTAssertTrue(goalHeader.exists)
        XCTAssertLessThan(nameField.frame.minY, goalHeader.frame.minY,
                          "Plan name must remain above goal when adjusting an existing plan.")
    }

    /// Drag to move (2026-09-05). Before this, rescheduling cost four taps and a sheet, and "Move"
    /// was not even in the row's context menu. The gesture is the feature, so it is pinned by the
    /// gesture: press a session, drag it onto another day, and the board must actually move it.
    @MainActor
    func testDraggingASessionOntoAnotherDayMovesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--seed-plan-5day", "--plan-tab"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        // The 5-day seed leaves rest days that explain themselves ("Rest. Fresh for tomorrow's
        // speed work."). The first such row is the drop target; its exact sentence follows the
        // neighbours the generator placed, so the match is on the rest, not the reason.
        let restRows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rest.'"))
        let restRow = restRows.firstMatch
        XCTAssertTrue(restRow.waitForExistence(timeout: 25),
                      "The board should show an explained rest day.")
        let restBefore = restRows.count

        // Tuesday's easy run: the third of the three identical easy runs, top to bottom.
        let runs = app.buttons.matching(NSPredicate(format: "label CONTAINS '5 mi'"))
        XCTAssertGreaterThanOrEqual(runs.count, 3, "The 5-day seed should plan three easy runs.")
        let tuesdayRun = runs.element(boundBy: 2)
        XCTAssertTrue(tuesdayRun.exists)

        // The drag handle is the session's glyph, which sits just left of the row body and is
        // deliberately not its own accessibility element (the row already carries the session and
        // a "Move to another day" action), so it is addressed by coordinate. The glyph spans
        // roughly 44 to 10 points left of the body's leading edge.
        let handle = tuesdayRun.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: -25, dy: 0))
        let target = restRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // The full drag-and-drop form: a press to lift the session, a slow travel so the drop
        // destination registers the hover, and a hold at the target before release. The plain
        // `press(forDuration:thenDragTo:)` releases too fast for a drop session to commit.
        handle.press(forDuration: 0.8, thenDragTo: target,
                     withVelocity: .slow, thenHoldForDuration: 1.0)

        // The receipt names the day it landed on...
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Moved to'")).firstMatch.waitForExistence(timeout: 10),
                      "Dropping a session on a day should confirm where it landed.")
        // ...and that day is no longer a rest day, which is the move actually happening rather than
        // a toast fired over an unchanged board: one fewer rest row than before the drop.
        let fewer = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in restRows.count < restBefore }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [fewer], timeout: 8), .completed,
                       "The day the session was dropped on must stop reading as a rest day.")
    }

    /// The intensity mix reaches a SCREEN (2026-09-05).
    ///
    /// `IntensityMix` was written and unit-tested at the endurance pivot and then rendered on no
    /// surface at all for months — the recurring failure mode in this codebase is an engine that
    /// computes something true and shows it to nobody. Unit tests cannot catch that, because the
    /// engine passes them either way. This walks the real page and looks for the words.
    @MainActor
    func testTheIntensityMixReachesThePlanPage() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-pro", "--plan-tab"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        // The coach's read sits below the week board, so the card is always a scroll away.
        let card = app.staticTexts["YOUR RECENT MIX"]
        for _ in 0..<8 where !card.exists {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5),
                      "The demo athlete has ten runs in the last six weeks; their easy/quality split must be on the page.")
    }
}
