import XCTest

/// Opens Progress → Trends and verifies the weekly load/distance charts render with seeded data.
final class ProgressChartsUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Swipe down the page until the element exists (or the attempts run out). The Trends page is
    /// a long sectioned report — content low on the page isn't in the accessibility snapshot until
    /// it nears the viewport.
    @discardableResult
    private func swipeUntilFound(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 12) -> Bool {
        var found = element.waitForExistence(timeout: 3)
        var tries = 0
        while !found && tries < attempts {
            app.swipeUp()
            found = element.exists
            tries += 1
        }
        return found
    }

    func testWeeklyChartsShowValues() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()   // clear any permission alert via the interruption monitor

        // Switch to the Progress tab.
        let progressTab = app.tabBars.buttons["Progress"]
        XCTAssertTrue(progressTab.waitForExistence(timeout: 15), "Progress tab not found.")
        progressTab.tap()

        // The trend charts should render on the default Trends segment. The default range decides the
        // granularity word — "Daily …" (1W) or "Weekly …" (wider windows) — so assert on the metric,
        // not the prefix, and the test stays valid whatever the default window is. Each chart card
        // is ONE accessibility element (children ignored) whose label is the card title — match the
        // element's label type-agnostically (the visible title is now an uppercase eyebrow, so a
        // StaticText query on the title-case string no longer applies).
        // The 2026-07-22 Essentials redesign: the week strip leads, distance stays the flagship,
        // steps and totals join the free tier. (The standalone training-load chart retired — its
        // story lives in the Fitness & Freshness curve and the athlete panel's ACWR readout.)
        let thisWeek = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] %@", "This week")).firstMatch
        XCTAssertTrue(swipeUntilFound(thisWeek, in: app), "This-week strip not found.")
        let distance = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH %@", "distance")).firstMatch
        XCTAssertTrue(swipeUntilFound(distance, in: app), "Distance chart not found.")
        let steps = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] %@", "Daily steps")).firstMatch
        XCTAssertTrue(swipeUntilFound(steps, in: app), "Steps card not found.")
        let totals = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] %@", "Totals")).firstMatch
        XCTAssertTrue(swipeUntilFound(totals, in: app), "Totals card not found.")

        // The Oura tap-through (2026-07-23): tapping a card opens its detail — bigger chart,
        // year-long windows, stats, the explainer prose. Tap the DISTANCE card's header strip:
        // the plot area keeps its scrub gesture, so a dead-center tap could pin a bar instead.
        XCTAssertTrue(swipeUntilFound(distance, in: app), "Distance chart lost after scrolling.")
        distance.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        XCTAssertTrue(app.navigationBars["Weekly distance"].waitForExistence(timeout: 6),
                      "Distance card tap didn't open its detail sheet.")
        XCTAssertTrue(app.buttons["past year"].waitForExistence(timeout: 4),
                      "Detail sheet's 1Y range missing.")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "trend-detail-sheet"
        shot.lifetime = .keepAlways
        add(shot)
        // The year window actually loads (the detail's differentiator over the page picker).
        app.buttons["past year"].tap()
        XCTAssertTrue(app.staticTexts["Latest · past year"].waitForExistence(timeout: 6),
                      "1Y window didn't load in the detail sheet.")
        app.buttons["Done"].tap()
        // The page's elements report `exists` even under a mid-dismiss sheet — wait for the
        // sheet itself to leave before tapping anything beneath it.
        XCTAssertTrue(app.navigationBars["Weekly distance"].waitForNonExistence(timeout: 4),
                      "Distance detail sheet didn't dismiss.")
        XCTAssertTrue(distance.waitForExistence(timeout: 4), "Didn't return to Trends after Done.")

        // Steps reads against a ~20k axis ceiling (an ordinary day sits mid-chart, never
        // towering to full height) — open its detail and capture it for the eyeball check.
        XCTAssertTrue(swipeUntilFound(steps, in: app), "Steps card lost after returning.")
        if !steps.isHittable { app.swipeUp() }
        steps.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        if !app.navigationBars["Daily movement"].waitForExistence(timeout: 4) {
            steps.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        }
        XCTAssertTrue(app.navigationBars["Daily movement"].waitForExistence(timeout: 6),
                      "Steps card tap didn't open its detail sheet.")
        let stepsShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        stepsShot.name = "steps-detail-sheet"
        stepsShot.lifetime = .keepAlways
        add(stepsShot)
        app.buttons["Done"].tap()
    }

    /// The consistency heatmap collapses its 112 color-only cells into ONE VoiceOver element with an
    /// active-days summary (PRD §13.4). Verify that element is actually exposed with a value — proof
    /// the iridescence isn't the sole carrier of meaning.
    func testHeatmapExposesVoiceOverSummary() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // The consistency summary lives on Profile → Highlights (decision: consistency is a
        // Profile section, not a Progress chart) — the original assertion scrolled the wrong tab.
        let profileTab = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15), "Profile tab not found.")
        profileTab.tap()
        let highlights = app.buttons["Highlights"]
        XCTAssertTrue(highlights.waitForExistence(timeout: 10), "Highlights tab not found.")
        highlights.tap()

        // Scroll down until the heatmap element (value "N of M days active…") appears.
        let summary = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS[c] %@", "days active")).firstMatch
        var found = summary.waitForExistence(timeout: 3)
        var attempts = 0
        while !found && attempts < 6 {
            app.swipeUp()
            found = summary.exists
            attempts += 1
        }
        XCTAssertTrue(found, "Heatmap VoiceOver summary element not exposed.")
    }

    /// The recovery/readiness card (PRD §4.8) renders in the Pro analytics block with a readiness
    /// band + score exposed to VoiceOver. --seed-demo grants Pro and enough history for `hasData`.
    func testRecoveryCardRenders() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        let progressTab = app.tabBars.buttons["Progress"]
        XCTAssertTrue(progressTab.waitForExistence(timeout: 15), "Progress tab not found.")
        progressTab.tap()

        // The strip exposes label "Readiness" with the score as its VALUE ("100 out of 100, Primed").
        // Anchoring on the label+value pair proves the score reaches VoiceOver — a bare "Recovery"
        // label would also match the HR-zones Z1 row, whose value is empty. The strip lives in the
        // Coach chapter at the bottom of the report — allow enough swipes to get there.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Readiness' AND value CONTAINS 'out of 100'")).firstMatch
        var found = card.waitForExistence(timeout: 3)
        var attempts = 0
        while !found && attempts < 14 {
            app.swipeUp()
            found = card.exists
            attempts += 1
        }
        XCTAssertTrue(found, "Recovery readiness card not exposed.")
    }
}
