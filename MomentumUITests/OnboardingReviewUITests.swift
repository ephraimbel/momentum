import XCTest

/// The review beat between the plan reveal and checkout (owner call 2026-09-05): the native App
/// Store sheet is raised on arrival, without a tap.
///
/// This app was rejected under guideline 5.6.3 in 2026-07 for a rating ask standing as an
/// onboarding step, so the shape of this one is not incidental — it is the whole reason the beat
/// is allowed to exist. These tests pin the four things that keep it out of that shape:
///
///   1. `Continue` is present and hittable WHILE the system sheet is up. The ask never gates,
///      delays or hides the way forward.
///   2. `Continue` is the page's only button — there is no custom rating UI, no star row to tap,
///      no "do you like momentum?" fork routing unhappy athletes somewhere other than the store.
///      Apple's `requestReview()` is the only rating surface.
///   3. The reveal still hands forward, so the plan is never replaced by the ask.
///   4. The page never claims a review was written. iOS reports nothing about what happened in
///      the sheet, so no thank-you copy may appear on this screen.
///
/// `--review-no-ask` holds the sheet for the tests that need to read the page underneath it (a
/// system surface covers and answers none of our queries). The test at 1. deliberately does NOT
/// pass it — that one has to fight the real sheet.
final class OnboardingReviewUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(holdingSheet: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-review"]
        if holdingSheet { app.launchArguments.append("--review-no-ask") }
        app.launch()
        return app
    }

    /// 1. The ask comes up on its own and Continue survives it.
    @MainActor func testContinueStaysAvailableWhileTheAskIsUp() {
        let app = launch(holdingSheet: false)
        let cta = app.buttons["onboarding.review.continue"]
        XCTAssertTrue(cta.waitForExistence(timeout: 20))
        // The sheet is raised 0.5s after the page settles; wait past it and check again. A
        // system sheet that DISABLED the way forward is exactly the rejected shape.
        XCTAssertTrue(cta.waitForExistence(timeout: 5))
        XCTAssertTrue(cta.isEnabled, "The way forward must never be gated on the review ask")
    }

    /// 2. One button, no home-grown rating widget.
    @MainActor func testPageOffersNoCustomRatingUI() {
        let app = launch(holdingSheet: true)
        let cta = app.buttons["onboarding.review.continue"]
        XCTAssertTrue(cta.waitForExistence(timeout: 20))
        XCTAssertTrue(cta.isHittable)
        XCTAssertEqual(app.buttons.count, 1, "Continue must be the only control on the review beat")
        // The pre-prompt fork and the star row belong to no version of this page.
        XCTAssertFalse(app.staticTexts["Enjoying momentum?"].exists)
        XCTAssertFalse(app.buttons["Rate momentum"].exists)
        XCTAssertFalse(app.buttons["Maybe later"].exists)
        XCTAssertTrue(app.staticTexts["Help the next runner find momentum"].exists)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "onboarding-review-beat"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 4. Nothing on the page claims the athlete reviewed — we cannot know that.
    @MainActor func testPageNeverClaimsAReviewWasLeft() {
        let app = launch(holdingSheet: true)
        XCTAssertTrue(app.buttons["onboarding.review.continue"].waitForExistence(timeout: 20))
        for claim in ["Thanks for helping momentum grow", "Thanks for the review",
                      "Thanks for helping momentum grow.", "Review submitted"] {
            XCTAssertFalse(app.staticTexts[claim].exists, "\(claim) asserts something iOS never tells us")
        }
    }

    /// 3. The reveal's CTA leads here, and the plan is still the screen before it.
    @MainActor func testRevealHandsForwardToTheReviewBeat() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding",
                               "--onboarding-reveal", "--reveal-runs", "--review-no-ask"]
        app.launch()
        let revealCTA = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(revealCTA.waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["YOUR TRAINING BRIEFING"].exists,
                      "The plan must own the screen before the ask, never share it")
        revealCTA.tap()
        XCTAssertTrue(app.buttons["onboarding.review.continue"].waitForExistence(timeout: 10),
                      "The reveal hands to the review beat, which then hands to checkout")
    }
}
