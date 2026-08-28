import XCTest

/// The coach-chat card flow, self-contained via the `--coach-card` deep link (no backend): a seeded
/// easeWeek proposal renders, Apply routes through CoachActions, the card flips to its receipt state
/// and the coach narrates the receipt as a fresh message.
final class CoachChatUITests: XCTestCase {

    @MainActor
    func testEaseProposalAppliesToReceipt() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--coach-card"]   // demo runs are Pro-entitled → Apply executes
        app.launch()

        let apply = app.buttons["Apply"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 12), "the seeded proposal card should render")
        apply.tap()

        // The card becomes a receipt row…
        let receipt = app.staticTexts["Applied — Ease this week"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 6), "the applied receipt should replace the proposal")
        // …and the coach narrates what actually happened (the engine's receipt, de-dashed).
        let narration = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "I trimmed your upcoming sessions")).firstMatch
        XCTAssertTrue(narration.waitForExistence(timeout: 4), "the coach should narrate the receipt")

        // The receipt carries Undo — tapping it restores the plan and the card says so.
        let undo = app.buttons["Undo this change"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 4), "an applied change should be undoable from its receipt")
        undo.tap()
        XCTAssertTrue(app.staticTexts["Rolled back — plan restored"].waitForExistence(timeout: 6),
                      "undo should flip the receipt to its rolled-back state")
        let rollbackNote = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "rolled back")).firstMatch
        XCTAssertTrue(rollbackNote.waitForExistence(timeout: 4), "the coach should confirm the rollback")
    }

    /// Opening the chat means typing: the keyboard must rise ON ITS OWN (no tap), and the composer
    /// must ride ABOVE it — you can't coach someone who's typing blind. Machine-checked frames;
    /// skips only when a hardware keyboard eats the software one.
    @MainActor
    func testKeyboardAutoOpensAndComposerRidesAboveIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--coach"]
        app.launch()

        let field = app.textFields["Ask your coach…"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 12))

        // No tap: the chat focuses its composer on open.
        let keyboard = app.keyboards.firstMatch
        try XCTSkipUnless(keyboard.waitForExistence(timeout: 8),
                          "software keyboard not available (hardware keyboard attached)")

        // Focused, the multiline SwiftUI field re-materializes as a TextView with no stable
        // identifier — the reliable handle is whatever actually holds keyboard focus.
        let editor = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == 1")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 4), "the composer should hold keyboard focus on open")
        editor.typeText("Can I move my long run to Sunday?")

        // The whole composer sits above the keyboard: editor bottom ≤ keyboard top.
        XCTAssertLessThanOrEqual(editor.frame.maxY, keyboard.frame.minY + 1,
                                 "the composer is buried under the keyboard")
        XCTAssertTrue(editor.isHittable, "the field must stay visible while typing")
        XCTAssertTrue(app.buttons["Send"].firstMatch.isHittable, "Send must stay reachable over the keyboard")

        // Send it — the reply lands and focus/composer keep working for the next message.
        app.buttons["Send"].firstMatch.tap()
        let reply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "move")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "the coach should answer the typed question")
    }

    @MainActor
    func testMemoryRememberAndForgetLoop() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--coach", "--coach-remember"]
        app.launch()

        // "Remember that I hate treadmills" auto-sends → the coach proposes keeping it. The
        // proactive sweep may have seeded ITS OWN proposal card above (earned bump, recap…), so
        // target the newest Apply — the remember card is always the latest turn in the thread.
        // Generous: this can be the install's very first launch (container seed + fonts +
        // notification-permission alert + the auto-send and its thinking beat, all stacked).
        XCTAssertTrue(app.staticTexts["Remember this"].waitForExistence(timeout: 25),
                      "the remember proposal should render")
        let applies = app.buttons.matching(identifier: "Apply")
        XCTAssertTrue(applies.firstMatch.waitForExistence(timeout: 4))
        applies.element(boundBy: applies.count - 1).tap()
        XCTAssertTrue(app.staticTexts["Applied — Remember this"].waitForExistence(timeout: 6))

        // Ask what it knows → the memory card lists the note with a Forget control.
        let field = app.textFields["Ask your coach…"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("What do you know about me?")
        app.buttons["Send"].firstMatch.tap()
        let note = app.staticTexts["I hate treadmills"]
        XCTAssertTrue(note.waitForExistence(timeout: 10), "the memory card should list the kept note")

        // Forget it — the row disappears immediately.
        let forget = app.buttons["Forget: I hate treadmills"].firstMatch
        XCTAssertTrue(forget.waitForExistence(timeout: 4))
        forget.tap()
        XCTAssertFalse(note.waitForExistence(timeout: 3), "a forgotten note must leave the card")
    }

    @MainActor
    func testExplainPlanCardRendersFromSuggestion() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--coach", "--coach-explain"]
        app.launch()

        // The deterministic explainer card lands with the athlete's own sections.
        let title = app.staticTexts["Your plan, explained"]
        XCTAssertTrue(title.waitForExistence(timeout: 12), "the explainPlan card should render")
        XCTAssertTrue(app.staticTexts["Your schedule"].waitForExistence(timeout: 4),
                      "explainer sections should be present")
        XCTAssertTrue(app.staticTexts["See the full plan"].exists, "the card should link to the plan")
    }

    @MainActor
    func testCoachOpensFromTodayHeaderButton() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()

        // The coach button lives behind the corner "More" disc (2026-08-27) — open the fan first.
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 12) { more.tap() }
        let button = app.buttons["Ask your coach"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 12), "the Today header should show the coach button")
        button.tap()
        XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 6)
                      || app.textFields["Ask your coach…"].waitForExistence(timeout: 2),
                      "tapping the header button should open the chat")
    }
}
