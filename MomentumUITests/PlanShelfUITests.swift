import XCTest

/// The plan lifecycle surfaces (2026-09-07): Your plans (the shelf), the plan builder, and
/// Manage plan. Each test drives one main flow end to end on the simulator against the real
/// generator and the real store, and one of them relaunches to prove the draft survived.
final class PlanShelfUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func testBuilderDistinguishesNoRunningFromUnknownAndCreatesAPreview() {
        let app = launch(["--reset-store", "--seed-demo", "--debug-pro", "--plan-tab", "--plan-builder"])
        let path = app.descendants(matching: .any)["builder-path-start"].firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 20)); path.tap()
        let next = app.descendants(matching: .any)["builder-continue"].firstMatch
        next.tap(); next.tap()
        let none = app.buttons.matching(NSPredicate(format: "label == %@", "Not running")).firstMatch
        XCTAssertTrue(none.waitForExistence(timeout: 10))
        if !none.isHittable { app.swipeUp() }
        none.tap()
        XCTAssertTrue(none.isSelected)
        let unsure = app.buttons.matching(NSPredicate(format: "label == %@", "Not sure")).firstMatch
        XCTAssertFalse(unsure.isSelected)
        unsure.tap()
        XCTAssertTrue(unsure.isSelected)
        XCTAssertFalse(none.isSelected)
        none.tap()
        shot(app, "builder-explicit-zero-running")
        next.tap(); next.tap(); next.tap()
        let start = app.descendants(matching: .any)["builder-start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: start)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 20), .completed)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Every number is a floor")).firstMatch.exists)
        shot(app, "builder-returning-preview")
        app.descendants(matching: .any)["builder-draft"].firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Plan"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testInterruptedDeviceResetSurvivesRelaunchAndFinishesIntoSetup() {
        let app = launch(["--reset-store", "--seed-demo", "--debug-pro", "--plan-reset-interrupted"])
        XCTAssertTrue(app.buttons["plan.reset.finish"].waitForExistence(timeout: 20))
        shot(app, "interrupted-device-reset")
        app.terminate()
        app.launchArguments = ["--seed-demo", "--debug-pro"]
        app.launch()
        let finish = app.buttons["plan.reset.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 20), "Reset intent must survive a fresh process without the seed flag.")
        finish.tap()
        XCTAssertTrue(app.textFields["Your name"].waitForExistence(timeout: 20), "Completing the reset should open fresh onboarding.")
        XCTAssertFalse(app.buttons["plan.reset.finish"].exists)
        shot(app, "completed-device-reset-setup")
    }

    @MainActor
    func testIllnessPausePersistsAndOpensTheSharedRecoveryCheckIn() {
        let app = launch(["--reset-store", "--seed-demo", "--debug-pro", "--plan-tab", "--plan-manage"])
        XCTAssertTrue(app.staticTexts["manage plan"].waitForExistence(timeout: 20))
        let unwell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "I'm not feeling well")).firstMatch
        XCTAssertTrue(unwell.waitForExistence(timeout: 10))
        unwell.tap()
        let pause = app.buttons["illness.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        shot(app, "illness-before-pause")
        pause.tap()
        XCTAssertTrue(app.staticTexts["manage plan"].waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["illness.banner"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--seed-demo", "--debug-pro", "--plan-tab"]
        app.launch()
        let banner = app.buttons["illness.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        banner.tap()
        XCTAssertTrue(app.staticTexts["Rest comes first"].waitForExistence(timeout: 5))
        app.buttons["illness.checkin"].tap()
        XCTAssertTrue(app.alerts["Your next step"].waitForExistence(timeout: 5),
                      "An unanswered check-in must not resume training.")
        app.alerts.buttons["OK"].tap()
        shot(app, "illness-restored-checkin")
        XCTAssertTrue(app.staticTexts["Rest comes first"].exists)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        return app
    }

    /// The shelf lists the current plan and every shelved status, and Create opens the builder;
    /// Cancel from the builder returns to the shelf rather than to the Plan page.
    @MainActor
    func testShelfListsEveryStatusAndCreateOpensTheBuilder() {
        let app = launch(["--reset-store", "--seed-demo", "--seed-plan-shelf", "--plan-tab", "--plan-your-plans"])

        XCTAssertTrue(app.staticTexts["your plans"].waitForExistence(timeout: 20), "Your plans did not open.")
        XCTAssertTrue(app.descendants(matching: .any)["plans-current"].firstMatch.waitForExistence(timeout: 10),
                      "The current plan card is missing.")
        for status in ["draft", "upcoming", "completed"] {
            XCTAssertTrue(app.descendants(matching: .any)["plans-\(status)"].firstMatch.waitForExistence(timeout: 5),
                          "A seeded \(status) plan card is missing.")
        }
        shot(app, "1-your-plans")

        let create = app.descendants(matching: .any)["plans-create"].firstMatch
        XCTAssertTrue(create.exists, "Create a plan is the shelf's primary action.")
        create.tap()
        XCTAssertTrue(app.descendants(matching: .any)["builder-path-race"].firstMatch.waitForExistence(timeout: 10),
                      "The builder should open on its goal step.")
        shot(app, "2-builder-goal")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["your plans"].waitForExistence(timeout: 10),
                      "Cancelling a builder opened from the shelf returns to the shelf.")
    }

    /// Goal → target → where you are → your week → how to train → the preview → Save as draft,
    /// then a relaunch on the same store: the draft is on the shelf. Nothing was activated.
    @MainActor
    func testBuilderSavesADraftThatSurvivesRelaunch() {
        let app = launch(["--reset-store", "--seed-demo", "--plan-tab", "--plan-builder"])

        let door = app.descendants(matching: .any)["builder-path-start"].firstMatch
        XCTAssertTrue(door.waitForExistence(timeout: 20), "The builder did not open.")
        door.tap()
        let next = app.descendants(matching: .any)["builder-continue"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        // Target → where you are → your week → how to train → See the plan.
        for step in 1...5 {
            XCTAssertTrue(next.waitForExistence(timeout: 5), "Continue missing at step \(step).")
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: next)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 5), .completed, "Continue stayed disabled at step \(step).")
            next.tap()
        }
        let draft = app.descendants(matching: .any)["builder-draft"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 15), "The preview step should offer Save as draft.")
        // The preview renders the real generator's numbers before anything can be committed.
        let start = app.descendants(matching: .any)["builder-start"].firstMatch
        let previewed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: start)
        XCTAssertEqual(XCTWaiter().wait(for: [previewed], timeout: 20), .completed, "The preview never settled.")
        shot(app, "1-builder-preview")
        draft.tap()

        // Back on the Plan page: the seeded plan is still the current one.
        XCTAssertTrue(app.tabBars.buttons["Plan"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["builder-draft"].firstMatch.waitForExistence(timeout: 2),
                       "The builder should close after saving a draft.")

        // Relaunch WITHOUT resetting the store: the draft persisted.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["--seed-demo", "--plan-tab", "--plan-your-plans"]
        again.launch()
        XCTAssertTrue(again.staticTexts["your plans"].waitForExistence(timeout: 20))
        XCTAssertTrue(again.descendants(matching: .any)["plans-draft"].firstMatch.waitForExistence(timeout: 10),
                      "The saved draft should be on the shelf after a relaunch.")
        XCTAssertTrue(again.descendants(matching: .any)["plans-current"].firstMatch.exists,
                      "Saving a draft must never touch the current plan.")
        shot(again, "2-draft-after-relaunch")
    }

    /// Something changed → This week is heavy → the proposal (computed, then Apply) → the receipt
    /// with Undo → Undo takes the change back.
    @MainActor
    func testManageProposalAppliesAndUndoes() {
        let app = launch(["--reset-store", "--seed-demo", "--debug-pro", "--plan-tab", "--plan-manage"])

        XCTAssertTrue(app.staticTexts["manage plan"].waitForExistence(timeout: 20), "Manage plan did not open.")
        shot(app, "1-manage")
        let heavy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'This week is heavy'")).firstMatch
        XCTAssertTrue(heavy.waitForExistence(timeout: 10), "The Something-changed row is missing.")
        heavy.tap()

        let apply = app.descendants(matching: .any)["proposal-apply"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 15), "The proposal sheet did not open.")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: apply)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 20), .completed,
                       "The proposal never finished computing (Apply stayed disabled).")
        XCTAssertTrue(app.staticTexts["Completed sessions are never touched."].exists,
                      "The proposal names what it touches and what it leaves alone.")
        shot(app, "2-proposal")
        apply.tap()

        let receipt = app.descendants(matching: .any)["manage-receipt"].firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 15), "Applying should leave a receipt on the page.")
        // The receipt card's identifier reaches its children, so the button is found by its word.
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "A fresh receipt offers Undo.")
        shot(app, "3-receipt")
        undo.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: receipt)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed,
                       "Undo should take the receipt away with the change.")
        XCTAssertTrue(heavy.waitForExistence(timeout: 5), "The row is offered again after Undo.")
    }
}
