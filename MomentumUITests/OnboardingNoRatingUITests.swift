import XCTest

/// The personal reveal stays focused on training. Ratings belong after actual engagement.
final class OnboardingNoRatingUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor func testRevealShowsTrainingWithoutAskingForAReview() {
        verifyScrollableReveal(reduceMotion: false)
    }

    @MainActor func testCompletePlanIsScrollableWithReducedMotion() {
        verifyScrollableReveal(reduceMotion: true)
    }

    @MainActor private func verifyScrollableReveal(reduceMotion: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-reveal"]
        if reduceMotion { app.launchArguments.append("--ui-test-reduce-motion") }
        app.launch()
        let cta = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(cta.waitForExistence(timeout: 20))
        XCTAssertTrue(cta.isHittable)
        XCTAssertTrue(app.staticTexts["YOUR TRAINING BRIEFING"].exists)
        XCTAssertFalse(app.buttons["onboarding.reveal.explore"].exists)
        XCTAssertFalse(app.buttons["Leave a review for momentum on the App Store"].exists)
        XCTAssertFalse(app.staticTexts["Enjoying momentum?"].exists)
        let scroll = app.scrollViews["onboarding.reveal.scroll"]
        XCTAssertTrue(scroll.exists)
        func reach(_ element: XCUIElement) {
            for _ in 0..<18 {
                if element.isHittable { break }
                scroll.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(element.isHittable, "Plan detail must be reachable without opening another page")
            XCTAssertTrue(cta.isHittable, "Continue must remain available while reading the plan")
        }
        reach(app.staticTexts["YOUR PATH"])
        let path = XCTAttachment(screenshot: app.screenshot())
        path.name = reduceMotion ? "plan-chart-first-reduced-motion" : "plan-chart-first"
        path.lifetime = .keepAlways
        add(path)
        reach(app.staticTexts["YOUR TRAINING BRIEFING"])
        reach(app.staticTexts["YOUR FIRST WEEK"])
        // Seeded hybrid plan has four first-week sessions. Each already contains its prescription.
        for index in 0..<4 {
            let card = app.otherElements["onboarding.reveal.session.\(index)"]
            reach(card)
            XCTAssertGreaterThan(card.staticTexts.count, 4, "Session details should already be expanded")
            XCTAssertEqual(card.buttons.count, 0, "The first week must not require disclosure taps")
        }
        let week = XCTAttachment(screenshot: app.screenshot())
        week.name = reduceMotion ? "first-week-reduced-motion" : "first-week-expanded"
        week.lifetime = .keepAlways
        add(week)
        reach(app.staticTexts["THE WEEKS AHEAD"])
        reach(app.descendants(matching: .any)["onboarding.reveal.week.6"].firstMatch)
        let end = XCTAttachment(screenshot: app.screenshot())
        end.name = reduceMotion ? "complete-plan-reduced-motion" : "complete-plan"
        end.lifetime = .keepAlways
        add(end)
        // Scroll back through sections: entrances must not reset or leave transparent content.
        for _ in 0..<18 {
            if app.staticTexts["YOUR TRAINING BRIEFING"].isHittable { break }
            scroll.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(app.staticTexts["YOUR TRAINING BRIEFING"].isHittable)
        XCTAssertTrue(cta.isHittable)
        XCTAssertFalse(app.buttons["Done"].exists)
    }

    func testNoRatingAskAnywhereAfterTheReveal() {
        let app = XCUIApplication()
        // Land on the notifications step. Since 2026-09-01 the two permission beats sit BEFORE
        // plan generation (notifications → location → building → reveal → account), so from here
        // to the app is every beat a rating ask could ever have lived on.
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-notifications"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // Notifications step: no rating ask here.
        let maybeLater = app.buttons["Maybe later"]
        XCTAssertTrue(maybeLater.waitForExistence(timeout: 15), "Expected the notifications step.")
        assertNoRatingSurface(app, on: "the notifications step")
        maybeLater.tap()

        // Location step: still no rating ask. Its CTA is "Continue" — it must NOT promise an ending,
        // since the reveal, the paywall and the account beat all still follow it.
        let locationContinue = app.buttons["Continue"]
        XCTAssertTrue(locationContinue.waitForExistence(timeout: 10), "Expected the location step.")
        assertNoRatingSurface(app, on: "the location step")
        XCTAssertFalse(app.buttons["Start training"].exists,
                       "The location step must not claim to end onboarding — beats follow it.")
        locationContinue.tap()

        // Continue hands to the build and then the plan reveal. No rating surface interrupts it.
        let revealCTA = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(revealCTA.waitForExistence(timeout: 30), "Expected the plan reveal after the build.")
        assertNoRatingSurface(app, on: "the plan reveal")
        revealCTA.tap()

        // This athlete is seeded Pro, so the wall stands down and the flow completes into the app.
        assertNoRatingSurface(app, on: "the hand-off after the reveal")
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20),
                      "Onboarding must complete into the app.")
    }

    private func assertNoRatingSurface(_ app: XCUIApplication, on screen: String) {
        XCTAssertFalse(app.buttons["Rate momentum"].exists, "No rating ask on \(screen).")
        XCTAssertFalse(app.staticTexts["A quick rating helps the next runner find theirs."].exists,
                       "No rating copy on \(screen).")
    }
}
