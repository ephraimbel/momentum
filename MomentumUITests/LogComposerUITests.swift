import XCTest

/// The offline log flow, driven the way an athlete drives it: describe the workout, fix what's
/// missing, log it, and find it in history.
///
/// The regression this pins: a lift described perfectly ("bench pressed 185 for 10 with 5 sets")
/// parsed perfectly and then could not be saved, because a workout needs a duration and nobody
/// narrates how long they benched. The confirm button greyed out with the reason buried in a card,
/// so the flow simply dead-ended. One tap on a duration chip must now complete it.
final class LogComposerUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(draft: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--log-activity-draft", draft]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSetsOnlyLiftIsLoggableInOneTap() {
        let app = launch(draft: "Bench pressed 185 for 10 with 5 sets")

        // The receipt read the lift exactly.
        XCTAssertTrue(app.staticTexts["Weight Training"].waitForExistence(timeout: 20),
                      "The composer never rendered a receipt for the lift.")
        XCTAssertTrue(app.staticTexts["5×10 · 185 lb"].exists, "The sets/weight line is missing.")

        // …and says out loud what's still missing, instead of a mute grey button.
        let blocked = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Add how long'")).firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 5),
                      "The confirm button should name the missing duration.")
        XCTAssertFalse(blocked.isEnabled, "It must stay disabled until there IS a duration.")
        attach(app, "1-lift-needs-duration")

        // One tap fills it.
        let chip = app.buttons["45 minutes"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "The quick-duration chips are missing.")
        chip.tap()
        XCTAssertTrue(app.staticTexts["45:00"].waitForExistence(timeout: 5),
                      "Tapping 45m didn't fill the receipt's duration.")

        let confirm = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Log workout'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "The confirm button never became loggable.")
        XCTAssertTrue(confirm.isEnabled, "With a sport and a duration the workout must be loggable.")
        attach(app, "2-ready-to-log")

        // Log it: the completion beat plays, then the composer closes on its own.
        confirm.tap()
        XCTAssertTrue(app.staticTexts["What did you do?"].waitForNonExistence(timeout: 20),
                      "The composer never dismissed after logging.")
        attach(app, "3-after-log")

        // And it's in the journal — History is where the athlete goes looking for it.
        XCTAssertTrue(app.tabBars.buttons["Progress"].waitForExistence(timeout: 10), "Progress tab missing.")
        app.tabBars.buttons["Progress"].tap()
        let history = app.buttons["History"]
        if history.waitForExistence(timeout: 10) { history.tap() }
        XCTAssertTrue(app.staticTexts["Weight Training"].waitForExistence(timeout: 15),
                      "The logged lift never appeared in History.")
        attach(app, "4-in-history")
    }

    /// Logging the same session again is most of what manual logging is. The blank slate offers the
    /// athlete's own recent workouts as sentences the parser is guaranteed to read back, so a repeat
    /// costs two taps instead of a re-typed sentence.
    func testARepeatChipFillsTheComposerAndLogsInTwoTaps() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--log-activity"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Log it again"].waitForExistence(timeout: 20),
                      "History exists, so the composer should offer it back as repeats.")
        let repeatChip = app.buttons.matching(NSPredicate(format: "label CONTAINS 'min lift'")).firstMatch
        XCTAssertTrue(repeatChip.waitForExistence(timeout: 5), "No repeat chip for the seeded lifts.")
        attach(app, "6-repeat-chips")

        repeatChip.tap()
        XCTAssertTrue(app.staticTexts["Weight Training"].waitForExistence(timeout: 10),
                      "Tapping a repeat didn't produce a receipt.")
        let confirm = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Log workout'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5) && confirm.isEnabled,
                      "A repeat must be complete enough to log on the spot.")
        attach(app, "7-repeat-receipt")
    }

    /// History is the other place an athlete notices a session is missing, and its "+" used to drop
    /// them into the raw form — no dictation, no receipt, stricter rules — while Today's Log button
    /// opened the composer. One flow, both doors.
    func testHistoryPlusOpensTheSameComposer() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--progress-tab"]
        app.launch()

        let history = app.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 20), "Progress never reached its History segment.")
        history.tap()
        let plus = app.buttons["Log a workout"]
        XCTAssertTrue(plus.waitForExistence(timeout: 8), "History's add button is missing.")
        plus.tap()
        XCTAssertTrue(app.staticTexts["What did you do?"].waitForExistence(timeout: 10),
                      "History's + must open the same log composer Today's Log button does.")
        attach(app, "8-history-entry")
    }

    /// A sport named without numbers is deliberately kept off the receipt — but the athlete has to
    /// be told, or the app logs half of what they said in silence.
    func testASportMentionedWithoutNumbersIsNamedNotSwallowed() {
        let app = launch(draft: "45 min upper body then went for a run")

        XCTAssertTrue(app.staticTexts["Weight Training"].waitForExistence(timeout: 20),
                      "The composer never rendered the lift.")
        let heard = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Heard'")).firstMatch
        XCTAssertTrue(heard.waitForExistence(timeout: 8),
                      "The run was dropped without a word — the composer must name what it heard and didn't log.")
        attach(app, "5-unlogged-mention")
    }
}
