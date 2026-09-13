import XCTest

/// The personal reveal stays focused on training: the plan owns its screen and no rating surface
/// shares it, or the permission beats before it.
///
/// The ask itself is NOT forbidden in onboarding any more — since 2026-09-05 it is a page of its
/// own between the reveal and checkout (`OnboardingReviewView`, whose own invariants live in
/// `OnboardingReviewUITests`). What this suite still pins is that the ask stays on that page and
/// nowhere else, and that the plan is never interrupted by it.
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
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-reveal", "--review-no-ask"]
        if reduceMotion { app.launchArguments.append("--ui-test-reduce-motion") }
        app.launch()
        let cta = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(cta.waitForExistence(timeout: 20))
        XCTAssertTrue(cta.isHittable)
        XCTAssertTrue(app.staticTexts["YOUR WEEK"].exists)
        XCTAssertFalse(app.buttons["onboarding.reveal.explore"].exists)
        XCTAssertFalse(app.buttons["Leave a review for momentum on the App Store"].exists)
        XCTAssertFalse(app.staticTexts["Enjoying momentum?"].exists)
        // The card names the opening session before any tap, and a tapped rest day says what
        // a rest day is for (never "nothing"). Buttons, not gestures.
        let callout = app.otherElements["onboarding.reveal.weekCallout"]
        XCTAssertTrue(callout.waitForExistence(timeout: 5))
        XCTAssertFalse(callout.label.contains("Rest."), "the opening session is chosen first: \(callout.label)")
        let restDay = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', rest'")).firstMatch
        let trainingDay = app.buttons.matching(NSPredicate(format: "label CONTAINS ', ' AND NOT label ENDSWITH ', rest'")).firstMatch
        if restDay.exists, trainingDay.exists {
            restDay.tap()
            XCTAssertTrue(callout.label.contains("Rest."), callout.label)
            trainingDay.tap()
            XCTAssertFalse(callout.label.contains("Rest."), callout.label)
        }
        // Every session lives one tap away (the package redesign, 2026-09-13): the sheet holds
        // the briefing, the complete first week and the weeks ahead, in that order.
        let details = app.buttons["onboarding.reveal.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 8))
        details.tap()
        let scroll = app.scrollViews["onboarding.reveal.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 8))
        func reach(_ element: XCUIElement) {
            for _ in 0..<18 {
                if element.isHittable { break }
                scroll.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(element.isHittable, "Plan detail must be reachable inside the sheet")
        }
        reach(app.staticTexts["YOUR TRAINING BRIEFING"])
        XCTAssertTrue(app.staticTexts["onboarding.reveal.firstSession"].exists)
        let path = XCTAttachment(screenshot: app.screenshot())
        path.name = reduceMotion ? "plan-chart-first-reduced-motion" : "plan-chart-first"
        path.lifetime = .keepAlways
        add(path)
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
        XCTAssertFalse(app.buttons["Done"].exists)
        // Closing the sheet lands back on the card with Continue live.
        app.buttons["Close"].tap()
        XCTAssertTrue(cta.waitForExistence(timeout: 5))
        XCTAssertTrue(cta.isHittable)
    }

    func testReviewIsOptionalAndDoesNotReturnOnToday() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-reveal", "--review-no-ask"]
        app.launch()
        let cta = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(cta.waitForExistence(timeout: 20))
        cta.tap()
        let review = app.buttons["onboarding.review.continue"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        crossPermissionBeats(app)
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))
        assertNoRatingSurface(app, on: "entry to Today")
        XCTAssertFalse(app.staticTexts["Save your progress"].exists)
    }

    private func assertNoRatingSurface(_ app: XCUIApplication, on screen: String) {
        XCTAssertFalse(app.buttons["Rate momentum"].exists, "No rating ask on \(screen).")
        XCTAssertFalse(app.staticTexts["A quick rating helps the next runner find theirs."].exists,
                       "No rating copy on \(screen).")
    }
}
