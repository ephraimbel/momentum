import XCTest

/// The workout library (2026-07-23): Plan → + → "From the library" → browse → detail → add.
/// Verifies the whole picking flow lands a real session on the plan, with screenshots of the
/// catalog and the coach-brief detail along the way.
final class WorkoutLibraryUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPickAWorkoutFromTheLibrary() {
        let app = XCUIApplication()
        // --seed-plan-5day: a full committed plan — bare --seed-demo seeds no TrainingPlan,
        // and without one the Plan tab is (correctly) the create-a-plan empty state.
        app.launchArguments = ["--seed-demo", "--seed-plan-5day", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // Another suite's unfinished run can recover into the save screen on cold launch
        // (zero-lost-workouts is app behavior, not a bug) — file it away before navigating.
        let recoveredRun = app.buttons["Done"].firstMatch
        if recoveredRun.waitForExistence(timeout: 3), app.buttons["Share your run"].exists {
            recoveredRun.tap()
        }

        // Plan tab → the + (add session) → the library door.
        let planTab = app.tabBars.buttons["Plan"]
        XCTAssertTrue(planTab.waitForExistence(timeout: 15), "Plan tab not found.")
        planTab.tap()
        let add = app.buttons["Add session"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add session button not found.")
        add.tap()
        let door = app.buttons["Workout library"]
        XCTAssertTrue(door.waitForExistence(timeout: 6), "Library door not in the add sheet.")
        door.tap()

        // The catalog: categories with personalized cards. (The sheet swap has a 0.35 s beat.)
        XCTAssertTrue(app.navigationBars["Workout library"].waitForExistence(timeout: 8),
                      "Library sheet didn't open.")
        attach("library-catalog")

        // Open a workout: 400m repeats (first speed card). The card is one combined element.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "400m repeats")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 4), "400m repeats card not found.")
        card.tap()

        // The coach brief: personalized structure, dial, prose, day strip, add CTA.
        let cta = app.buttons["Add for today"]
        XCTAssertTrue(cta.waitForExistence(timeout: 6), "Detail CTA not found.")
        XCTAssertTrue(app.staticTexts["FROM YOUR COACH"].exists, "Coach prose missing.")
        attach("library-detail")

        // Size it up (10 reps), then add for today.
        let ten = app.buttons["10 reps"]
        XCTAssertTrue(ten.waitForExistence(timeout: 4), "Rep dial missing.")
        ten.tap()
        cta.tap()

        // Back on Plan with the session on today's board — found by its own coach rationale,
        // which no seeded plan session shares (the 5-day plan has intervals of its own).
        XCTAssertTrue(app.navigationBars["Workout library"].waitForNonExistence(timeout: 6),
                      "Library didn't dismiss after adding.")
        let session = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "top-end aerobic power")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 6), "Added session not on the plan board.")
        attach("plan-with-library-session")

        // The session's own detail: the athlete who tapped it later must still see what the
        // workout consists of — the structure rows and the coach's why.
        session.tap()
        let structureRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Warm")).firstMatch
        XCTAssertTrue(structureRow.waitForExistence(timeout: 6),
                      "Session detail doesn't show the workout structure.")
        let why = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "aerobic power")).firstMatch
        XCTAssertTrue(why.waitForExistence(timeout: 4),
                      "Session detail doesn't carry the coach's rationale.")
        attach("session-detail-from-library")
        // Dismiss the detail sheet (drag indicator sheets close via swipe; use the nav Done/close
        // if present, else swipe down).
        if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        else { app.swipeDown(velocity: .fast) }

        // Today renders with a plan thought after the add (which of today's sessions the deck
        // leads with is existing deck policy — the guided start itself is StructuredRunUITests'
        // job; here we prove the surface stands with the new session in the store).
        let todayTab = app.tabBars.buttons["Today"]
        XCTAssertTrue(todayTab.waitForExistence(timeout: 6), "Today tab not found.")
        todayTab.tap()
        let planThought = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Start")).firstMatch
        XCTAssertTrue(planThought.waitForExistence(timeout: 10), "Today deck didn't render.")
        attach("today-with-library-session")
    }
}
