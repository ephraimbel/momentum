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
    /// Scrolls until the element is on screen and HITTABLE, not merely present: a lazily built
    /// page reports `exists` for cards a screen below the fold, and a tap at their coordinate
    /// then lands on nothing (bit us 2026-08-27 when the This-week strip grew into a tile grid).
    private func swipeUntilFound(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 12) -> Bool {
        var found = element.waitForExistence(timeout: 3) && element.isHittable
        var tries = 0
        while !found && tries < attempts {
            app.swipeUp()
            found = element.exists && element.isHittable
            tries += 1
        }
        // Not below us — it may be ABOVE (the walker revisits the distance card after Totals).
        tries = 0
        while !found && tries < attempts {
            app.swipeDown()
            found = element.exists && element.isHittable
            tries += 1
        }
        if found { settle(element, in: app) }
        return found
    }

    /// Nudge a found card into the screen's middle band with a small precise drag: `isHittable`
    /// is true while a card's top rides under the pinned header (or its bottom under the tab
    /// bar), and the header-strip taps below then land on chrome instead of the card.
    private func settle(_ element: XCUIElement, in app: XCUIApplication) {
        let screen = app.frame
        for _ in 0..<3 {
            let f = element.frame
            var dy: CGFloat = 0
            if f.minY < 200 { dy = 220 - f.minY }                       // drag content DOWN
            else if f.maxY > screen.maxY - 140 { dy = -(f.maxY - (screen.maxY - 160)) }   // drag UP
            guard abs(dy) > 8 else { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)))
            usleep(400_000)
        }
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
        // Retry once, like the steps section below: right after the scroll settles the page can
        // still be finishing an entrance, and a single tap in that window can land on nothing.
        var distanceOpened = false
        for _ in 0..<2 where !distanceOpened {
            distance.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            distanceOpened = app.navigationBars["Weekly distance"].waitForExistence(timeout: 8)
        }
        XCTAssertTrue(distanceOpened, "Distance card tap didn't open its detail sheet.")
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
        // towering to full height) — open its detail. Tap the header strip (dy 0.1): the plot
        // keeps its scrub gesture, so a mid-card tap could pin a bar. Retry in a loop — right
        // after the distance sheet dismisses the page can still be settling, so a single tap can
        // land while the card is mid-scroll (the multi-suite flake this hardens against).
        XCTAssertTrue(swipeUntilFound(steps, in: app), "Steps card lost after returning.")
        var stepsOpened = app.navigationBars["Daily movement"].exists
        var stepsTries = 0
        while !stepsOpened && stepsTries < 5 {
            if steps.isHittable {
                steps.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            } else {
                app.swipeUp()
            }
            stepsOpened = app.navigationBars["Daily movement"].waitForExistence(timeout: 3)
            stepsTries += 1
        }
        XCTAssertTrue(stepsOpened, "Steps card tap didn't open its detail sheet.")
        let stepsShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        stepsShot.name = "steps-detail-sheet"
        stepsShot.lifetime = .keepAlways
        add(stepsShot)
        app.buttons["Done"].tap()
    }

    /// The Progress page carries the profile's consistency grid (owner call 2026-08-28) in place of
    /// the eight-week pill calendar, and its tap opens the depth sheet. Pins the ONE VoiceOver
    /// summary element on Progress and the door it opens.
    func testProgressConsistencyCardOpensItsDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--progress-tab", "--progress-scroll-calendar"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        let card = app.buttons.matching(NSPredicate(format: "label == %@ AND value CONTAINS[c] %@",
                                                    "Consistency", "days active")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Consistency grid not on Progress.")
        card.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8), "Consistency detail sheet didn't open.")
        XCTAssertTrue(app.staticTexts["BEST STREAK"].waitForExistence(timeout: 4),
                      "Detail sheet is missing its numbers.")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "consistency-detail-sheet"; shot.lifetime = .keepAlways; add(shot)
        done.tap()
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
