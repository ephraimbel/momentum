import XCTest

/// Onboarding and the auth pages must open fast and never stall under a real hand (owner ask
/// 2026-08-28: "it must never glitch"). Measures are log-only — never baseline-gated, so simulator
/// variance can't fail a run — but the responsiveness assertions are real.
final class OnboardingPerfUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// Cold launch → the first question on screen.
    func testOnboardingOpensFast() {
        measure(metrics: [XCTClockMetric()]) {
            let app = XCUIApplication()
            // UI tests share one simulator container. Reset every iteration so an existing demo
            // profile or recovery marker cannot steal the presentation slot from onboarding and
            // turn this launch benchmark into a test of whatever the prior suite left open.
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest"]
            app.launch()
            XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 20), "onboarding never opened")
            app.terminate()
        }
    }

    /// Every step answers the next tap. The flow debounces advances at 0.45s, so a human-speed
    /// walk must still move: this taps as fast as the debounce allows and proves the flow keeps
    /// up rather than dropping taps or wedging mid-transition.
    func testEveryStepStaysResponsive() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--debug-free", "--onboarding-goal", "--review-no-ask"]
        app.launch()
        let headings = ["What are we training for?", "Where are you with running?", "How fast do you run today?", "Anything to train around?", "A few personal details.", "Let's shape your training week.", "Here's the approach we recommend."]
        for (index, heading) in headings.enumerated() {
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 8), "Missing screen \(heading)")
            if index == 0 { app.buttons.matching(NSPredicate(format: "label CONTAINS 'Stay consistent'")).firstMatch.tap() }
            if index == 1 { app.buttons.matching(NSPredicate(format: "label CONTAINS 'New to running'")).firstMatch.tap() }
            if index == 2 { app.buttons.matching(NSPredicate(format: "label CONTAINS 'Walk and jog'")).firstMatch.tap() }   // by feel
            if heading == "A few personal details." {
                app.buttons["Female"].tap()
                app.buttons["Increase Age"].tap()
                app.buttons["Increase Height"].tap()
                app.buttons["Increase Weight"].tap()
            }
            let next = app.buttons["Continue"]
            XCTAssertTrue(next.isEnabled && next.isHittable)
            next.tap()
        }
        let reveal = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 15))
        XCTAssertTrue(reveal.isHittable)
        XCTAssertFalse(app.alerts.firstMatch.exists, "No permission request before the plan")
        reveal.tap()
        let review = app.buttons["onboarding.review.continue"]
        XCTAssertTrue(review.waitForExistence(timeout: 10) && review.isHittable)
        review.tap()
        crossPermissionBeats(app)
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.review.continue"].isHittable, "Checkout must own interaction over the review page")
    }

    /// The sign-in page opens and its fields take input immediately.
    func testSignInPageOpensAndAcceptsInput() {
        let app = XCUIApplication()
        app.launchArguments = ["--signin-page", "--reset-auth", "--uitest-password"]
        measure(metrics: [XCTClockMetric()]) {
            app.launch()
            XCTAssertTrue(app.buttons["Continue with Google"].waitForExistence(timeout: 20),
                          "sign-in page never opened")
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["Continue with Google"].waitForExistence(timeout: 20))
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5), "no email field")
        email.tap(); email.typeText("runner@example.com")
        XCTAssertTrue(email.value as? String == "runner@example.com",
                      "field did not take input: \(String(describing: email.value))")
        // Still answering after the keyboard is up. NOT the Google button — the keyboard
        // legitimately covers it, and asserting on that measures iOS, not us. The password field
        // is what must still be reachable to keep typing.
        // `--uitest-password` renders the password as a plain field (it opts out of AutoFill so
        // iOS's "Use Strong Password?" sheet can't swallow typeText), so match either kind.
        let password = app.secureTextFields["Password"].exists
            ? app.secureTextFields["Password"] : app.textFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 3), "no password field")
        XCTAssertTrue(password.isHittable, "form wedged with the keyboard up")
        password.tap(); password.typeText("hunter2hunter2")
        XCTAssertTrue(app.buttons["Sign in"].exists, "primary CTA vanished while typing")
    }
    func testCombinedScheduleKeepsChoicesAndUnitsWhenGoingBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-days", "--ui-test-reduce-motion"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Let's shape your training week."].waitForExistence(timeout: 20))
        app.buttons["4 training days"].tap()
        app.buttons["Monday"].tap()
        app.buttons["Thursday"].tap()
        XCTAssertTrue(app.buttons["Monday"].isSelected)
        XCTAssertTrue(app.buttons["Thursday"].isSelected)
        app.buttons["onboarding.distanceUnits"].tap()
        app.buttons["Kilometres"].tap()
        app.buttons["onboarding.sessionLimits"].tap()
        XCTAssertTrue(app.staticTexts["How much time do you have?"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Let's shape your training week."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Monday"].isSelected)
        XCTAssertTrue(app.buttons["Thursday"].isSelected)
        XCTAssertTrue(app.buttons["onboarding.distanceUnits"].label.contains("km"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "onboarding-combined-schedule"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testPrimaryQuestionsKeepControlsReachable() {
        let app = XCUIApplication()
        let pages: [(String, String)] = [
            ("--onboarding-goal", "Become a stronger runner"),
            ("--onboarding-race", "Target finish time"),
            ("--onboarding-experience", "Returning after a break"),
            ("--onboarding-pace", "Increase Easy run pace"),
            ("--onboarding-volume", "I'm not sure"),
            ("--onboarding-musclefocus", "Core"),
            ("--onboarding-injuries", "No injuries, I'm all clear"),
            ("--onboarding-metrics", "Increase Weight"),
            ("--onboarding-equipment", "Strength preferences"),
            ("--onboarding-intensity", "Adjust approach"),
            ("--onboarding-intensity-short", "Adjust approach")
        ]
        for (argument, label) in pages {
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", argument, "--ui-test-reduce-motion"]
            app.launch()
            let choice = argument == "--onboarding-equipment" ? app.buttons["onboarding.strengthPreferences"]
                : argument == "--onboarding-experience-hybrid" ? app.buttons["onboarding.liftingExperience"]
                : app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            let found = choice.waitForExistence(timeout: 15)
            if !found {
                let failure = XCTAttachment(screenshot: app.screenshot())
                failure.name = argument + "-missing-control"
                failure.lifetime = .keepAlways
                add(failure)
            }
            XCTAssertTrue(found, "Missing final control on \(argument)")
            for _ in 0..<8 {
                if choice.isHittable && choice.frame.maxY <= app.buttons["Continue"].frame.minY { break }
                app.swipeUp()
            }
            XCTAssertTrue(choice.isHittable, "\(label) must remain reachable")
            XCTAssertLessThanOrEqual(choice.frame.maxY, app.buttons["Continue"].frame.minY,
                                     "\(label) sits under Continue")
            XCTAssertGreaterThanOrEqual(app.buttons["Continue"].frame.minX, app.frame.minX + 22,
                                        "\(argument) widens the shared page margins")
            XCTAssertLessThanOrEqual(app.buttons["Continue"].frame.maxX, app.frame.maxX - 22)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = argument
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    @MainActor
    func testGoalStartsImmediatelyAndSupportingActivitiesPersist() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--ui-test-reduce-motion", "--onboarding-goal"]
        app.launch()
        XCTAssertTrue(app.staticTexts["What are we training for?"].waitForExistence(timeout: 15))
        let activities = app.buttons["onboarding.supportingActivities"]
        for _ in 0..<3 { if activities.isHittable { break }; app.swipeUp() }
        activities.tap()
        let strength = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Lift weights'")).firstMatch
        XCTAssertTrue(strength.waitForExistence(timeout: 5))
        strength.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(activities.waitForExistence(timeout: 5))
        XCTAssertTrue(activities.label.contains("Strength"))
    }

}
