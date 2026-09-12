import XCTest

/// The review ask owns a separate page after the plan. A rating is never required to enter.
final class OnboardingReviewUITests: XCTestCase {
    func testReviewContinueWorksOnFirstTapInBothMotionModes() {
        continueAfterFailure = false
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-review", "--review-no-ask"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            let cta = app.buttons["onboarding.review.continue"]
            XCTAssertTrue(cta.waitForExistence(timeout: 20))
            XCTAssertTrue(cta.isHittable)
            XCTAssertTrue(cta.isEnabled)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = reduced ? "review-reduced-motion" : "review-motion"
            image.lifetime = .keepAlways
            add(image)
            cta.tap()
            XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))
            XCTAssertFalse(app.buttons["onboarding.review.continue"].exists)
            app.terminate()
        }
    }
}
