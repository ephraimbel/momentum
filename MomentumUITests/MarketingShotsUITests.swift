import XCTest

/// Marketing capture helper (2026-08-28): drives the app to a screen a launch argument can't
/// reach on its own and writes the PNG straight to disk. Not a behavioral test — skipped unless
/// MOMENTUM_SHOT_DIR is set, so it never runs in CI.
final class MarketingShotsUITests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MOMENTUM_SHOT_DIR"]  }

    private func save(_ app: XCUIApplication, _ name: String) {
        guard let dir else { return }
        let png = app.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testPlanWeekWithRealSessions() throws {
        try XCTSkipIf(dir == nil, "set MOMENTUM_SHOT_DIR to capture")
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--seed-dense-history", "--seed-plan-long", "--plan-tab"]
        app.launch()
        // Week 1 opens on the current (part-spent) week; week 3 is a full training week. The
        // chips are a plain HStack of numerals, so tap by position — a "3" query is ambiguous.
        XCTAssertTrue(app.staticTexts["This week"].waitForExistence(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.366, dy: 0.198)).tap()
        Thread.sleep(forTimeInterval: 2.5)
        save(app, "Plan")
        // Scroll to the hard days — the sessions the plan's vocabulary is judged on.
        app.swipeUp(); app.swipeUp()
        Thread.sleep(forTimeInterval: 1.5)
        save(app, "PlanHardDays")
    }

    /// History's states — top, scrolled (sticky month header), and filtered.
    func testHistoryStates() throws {
        try XCTSkipIf(dir == nil, "set MOMENTUM_SHOT_DIR to capture")
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--seed-dense-history", "--progress-tab", "--progress-history"]
        app.launch()
        XCTAssertTrue(app.staticTexts[Date().formatted(.dateTime.month(.wide)).uppercased()].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        save(app, "history-top")
        app.swipeUp(); app.swipeUp()
        Thread.sleep(forTimeInterval: 1.2)
        save(app, "history-scrolled")
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        Thread.sleep(forTimeInterval: 1.2)
        let runs = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Runs'")).firstMatch
        if runs.waitForExistence(timeout: 4) { runs.tap() }
        Thread.sleep(forTimeInterval: 1.5)
        save(app, "history-runs")
    }

    /// The onboarding plan reveal, top to bottom.
    func testPlanRevealStates() throws {
        try XCTSkipIf(dir == nil, "set MOMENTUM_SHOT_DIR to capture")
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--onboarding", "--onboarding-reveal"]
        app.launch()
        XCTAssertTrue(app.staticTexts["PLAN READY"].waitForExistence(timeout: 25))
        Thread.sleep(forTimeInterval: 3)
        save(app, "reveal-top")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.5)
        save(app, "reveal-mid")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.5)
        save(app, "reveal-bottom")
    }
}