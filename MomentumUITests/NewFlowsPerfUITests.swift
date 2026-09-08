import XCTest

/// Responsiveness of the new plan and fuel flows (2026-09-07). XCUITest's own clock includes its
/// accessibility snapshots (seconds on a busy screen), so the numbers it prints are hang guards,
/// not measurements: the app writes its own tap-to-screen times through `PerfMark` to the
/// unified log (subsystem `app.momentum.perf`), and those are what a perf pass reads.
final class NewFlowsPerfUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func elapsed(_ label: String, _ block: () -> Bool) -> TimeInterval {
        let t0 = Date()
        let ok = block()
        let dt = Date().timeIntervalSince(t0)
        let note = XCTAttachment(string: "\(label): \(String(format: "%.0f", dt * 1000)) ms\(ok ? "" : " (did not appear)")")
        note.name = "timing-\(label)"; note.lifetime = .keepAlways; add(note)
        print("⏱ \(label): \(String(format: "%.0f", dt * 1000)) ms")
        XCTAssertTrue(ok, "\(label) never appeared")
        return dt
    }

    /// Plan tab → Your plans → Create → through the steps → the preview settles.
    @MainActor
    func testBuilderPreviewSettlesQuickly() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--plan-tab"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Plan"].waitForExistence(timeout: 20))
        // Open the shelf from the masthead menu.
        app.buttons["Plan options"].firstMatch.tap()
        let yourPlans = app.buttons["Your plans"].firstMatch
        XCTAssertTrue(yourPlans.waitForExistence(timeout: 5))
        let shelfOpen = elapsed("your-plans-open") {
            yourPlans.tap()
            return app.descendants(matching: .any)["plans-current"].firstMatch.waitForExistence(timeout: 5)
        }
        XCTAssertLessThan(shelfOpen, 8.0)

        let create = app.descendants(matching: .any)["plans-create"].firstMatch
        let builderOpen = elapsed("builder-open") {
            create.tap()
            return app.descendants(matching: .any)["builder-path-race"].firstMatch.waitForExistence(timeout: 5)
        }
        XCTAssertLessThan(builderOpen, 8.0)

        app.descendants(matching: .any)["builder-path-start"].firstMatch.tap()
        let next = app.descendants(matching: .any)["builder-continue"].firstMatch
        for _ in 1...5 {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: next)
            _ = XCTWaiter().wait(for: [enabled], timeout: 5)
            next.tap()
        }
        let start = app.descendants(matching: .any)["builder-start"].firstMatch
        let previewSettled = elapsed("builder-preview-settled") {
            let previewed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: start)
            return XCTWaiter().wait(for: [previewed], timeout: 15) == .completed
        }
        XCTAssertLessThan(previewSettled, 8.0)
    }

    /// Manage plan → a row → the proposal is computed and Apply is live.
    @MainActor
    func testManageProposalIsReadyQuickly() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-pro", "--plan-tab", "--plan-manage"]
        app.launch()
        XCTAssertTrue(app.staticTexts["manage plan"].waitForExistence(timeout: 20))
        let days = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Training days'")).firstMatch
        XCTAssertTrue(days.waitForExistence(timeout: 5))
        days.tap()
        // Pick 5 days and confirm: the rebuild preview is the heaviest proposal there is.
        let five = app.buttons["5 days a week"].firstMatch
        XCTAssertTrue(five.waitForExistence(timeout: 5))
        five.tap()
        let confirm = app.buttons["See the change"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        let apply = app.descendants(matching: .any)["proposal-apply"].firstMatch
        let ready = elapsed("manage-rebuild-proposal") {
            confirm.tap()
            guard apply.waitForExistence(timeout: 8) else { return false }
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: apply)
            return XCTWaiter().wait(for: [enabled], timeout: 10) == .completed
        }
        XCTAssertLessThan(ready, 8.0)
    }

    /// Fuel: a day switch and back, and a keystroke into the composer, both stay under a beat.
    @MainActor
    func testFuelDaySwitchAndTypingAreResponsive() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-pro", "--fuel", "--seed-fuel-today", "--seed-fuel-history", "--seed-fuel-photo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 25))
        let prev = app.descendants(matching: .any)["fuel-day-prev"].firstMatch
        let dayName = app.descendants(matching: .any)["fuel-day-label"].firstMatch
        XCTAssertTrue(prev.waitForExistence(timeout: 5))
        let back = elapsed("fuel-day-back") {
            prev.tap()
            let onYesterday = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Yesterday'"), object: dayName)
            return XCTWaiter().wait(for: [onYesterday], timeout: 5) == .completed
        }
        XCTAssertLessThan(back, 6.0)
        let home = elapsed("fuel-day-home") {
            dayName.tap()
            let today = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Today'"), object: dayName)
            return XCTWaiter().wait(for: [today], timeout: 5) == .completed
        }
        XCTAssertLessThan(home, 6.0)

        let field = app.descendants(matching: .any)["fuel-composer"].firstMatch
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { field.tap() }
        let typed = elapsed("fuel-type-12-chars") {
            field.typeText("banana toast")
            return true
        }
        // XCUITest types at a fixed cadence; a stalled main thread shows up as the whole burst
        // taking far longer than the keystrokes themselves.
        XCTAssertLessThan(typed, 6.0)
    }
}
