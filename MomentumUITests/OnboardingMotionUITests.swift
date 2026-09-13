import XCTest

/// XCUITest may call a partially covered control "hittable" even when its center is behind
/// the fixed Continue bar. Scroll its tap target into the visible question viewport first.
@MainActor
private func revealOnboardingControl(_ element: XCUIElement, in app: XCUIApplication) {
    XCTAssertTrue(element.waitForExistence(timeout: 15))
    func bottomEdge() -> CGFloat {
        let next = app.buttons["Continue"].firstMatch
        let hasQuestionFooter = next.isHittable && element.label != "Continue"
            && !app.navigationBars.buttons["Done"].exists
            && !app.navigationBars["Your recent result"].exists
        return hasQuestionFooter ? next.frame.minY - 8 : app.frame.maxY - 34
    }
    func visible() -> Bool {
        guard element.isHittable else { return false }
        return element.frame.midY + min(22, element.frame.height / 2) <= bottomEdge()
    }
    for _ in 0..<24 where !visible() {
        let scroll = app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        let top = max(app.frame.minY, scroll.frame.minY) + 12
        let bottom = min(scroll.frame.maxY, bottomEdge()) - 12
        let middle = (top + bottom) / 2
        // Short, directional drags cannot fling a tall accessibility row past the viewport.
        let distance = min(100, max(35, (bottom - top) / 3))
        let delta = element.frame.midY < middle ? distance : -distance
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: app.frame.midX, dy: middle))
            .press(forDuration: 0.05,
                   thenDragTo: origin.withOffset(CGVector(dx: app.frame.midX, dy: middle + delta)))
    }
    XCTAssertTrue(visible())
}

/// Motion may acknowledge a choice, but must never swallow it, delay Continue, or hide a row.
final class OnboardingMotionUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func testExplicitApproachKeepsItsRequiredDaysWhenGoingBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-intensity", "--ui-test-reduce-motion"]
        app.launch()
        let adjust = app.buttons["onboarding.approach.options"]
        revealOnboardingControl(adjust, in: app)
        adjust.tap()
        let podium = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Podium'")).firstMatch
        revealOnboardingControl(podium, in: app)
        podium.tap()
        XCTAssertTrue(podium.isSelected)
        app.buttons["Done"].tap()
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Let's shape your training week."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["5 training days"].isSelected)
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Here's the approach we recommend."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Podium"].exists)
        capture(app, name: "explicit-approach-after-backtracking")
    }

    @MainActor
    func testReturningRunnerCanDescribeZeroRecentRunning() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-goal", "--ui-test-reduce-motion"]
        app.launch()
        let goal = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Stay consistent'")).firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 20))
        goal.tap(); app.buttons["Continue"].tap()
        let returning = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Returning after a break'")).firstMatch
        XCTAssertTrue(returning.waitForExistence(timeout: 5))
        returning.tap()
        XCTAssertTrue(returning.isSelected)
        capture(app, name: "returning-runner-background")
        for _ in 0..<4 {
            if app.staticTexts["Your recent running."].exists { break }
            let next = app.buttons["Continue"]
            XCTAssertTrue(next.waitForExistence(timeout: 5) && next.isEnabled)
            next.tap()
        }
        let none = app.buttons["I haven't run in the last four weeks"]
        XCTAssertTrue(none.waitForExistence(timeout: 5))
        none.tap()
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        capture(app, name: "returning-runner-zero-recent-volume")
    }

    @MainActor
    func testGalleryWelcomeFlowsIntoEditableProfile() {
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--reset-auth"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            let start = app.buttons["welcome.gallery.start"]
            XCTAssertTrue(start.waitForExistence(timeout: 15))
            XCTAssertTrue(start.isHittable)
            let welcome = XCTAttachment(screenshot: app.screenshot())
            welcome.name = reduced ? "gallery-welcome-reduced" : "gallery-welcome"
            welcome.lifetime = .keepAlways
            add(welcome)
            start.tap()
            let name = app.textFields["Your name"]
            XCTAssertTrue(name.waitForExistence(timeout: 10))
            XCTAssertTrue(name.isHittable)
            XCTAssertFalse(start.exists)
            let profile = XCTAttachment(screenshot: app.screenshot())
            profile.name = reduced ? "gallery-profile-reduced" : "gallery-profile"
            profile.lifetime = .keepAlways
            add(profile)
            name.tap(); name.typeText("Maya")
            XCTAssertEqual(name.value as? String, "Maya")
            app.terminate()
        }
    }

    @MainActor
    func testWelcomeDragKeepsActionsStationaryAndUsable() {
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--reset-auth"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            let start = app.buttons["welcome.gallery.start"]
            XCTAssertTrue(start.waitForExistence(timeout: 15))
            let original = start.frame
            capture(app, name: reduced ? "welcome-before-drag-reduced" : "welcome-before-drag")
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.28))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.58))
            from.press(forDuration: 0.1, thenDragTo: to)
            XCTAssertEqual(start.frame.minY, original.minY, accuracy: 1)
            XCTAssertEqual(start.frame.minX, original.minX, accuracy: 1)
            XCTAssertTrue(start.isHittable)
            capture(app, name: reduced ? "welcome-drag-reduced" : "welcome-drag")
            app.buttons["I already have an account"].tap()
            XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 5))
            app.buttons["Back"].tap()
            XCTAssertTrue(start.waitForExistence(timeout: 5))
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
            let ready = NSPredicate(format: "exists == true AND hittable == true AND enabled == true")
            capture(app, name: "welcome-immediately-after-resume")
            expectation(for: ready, evaluatedWith: start)
            waitForExpectations(timeout: 5)
            capture(app, name: reduced ? "welcome-resumed-reduced" : "welcome-resumed")
            start.tap()
            XCTAssertTrue(app.staticTexts["Let's make it yours."].waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    @MainActor
    func testChoicesAndBackNavigationWorkWithAndWithoutMotion() {
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-goal"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            XCTAssertTrue(app.staticTexts["What are we training for?"].waitForExistence(timeout: 20))
            let goal = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Stay consistent'")).firstMatch
            XCTAssertTrue(goal.waitForExistence(timeout: 5))
            XCTAssertTrue(goal.isHittable)
            goal.tap()
            XCTAssertTrue(goal.isSelected)
            let alternative = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Become a stronger runner'")).firstMatch
            alternative.tap()
            XCTAssertTrue(alternative.isSelected)
            XCTAssertFalse(goal.isSelected)
            goal.tap()
            XCTAssertTrue(goal.isSelected)
            XCTAssertLessThanOrEqual(alternative.frame.maxY, app.buttons["Continue"].frame.minY)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = reduced ? "onboarding-choice-reduced-motion" : "onboarding-choice-motion"
            shot.lifetime = .keepAlways
            add(shot)

            app.buttons["Continue"].doubleTap()
            XCTAssertTrue(app.staticTexts["Where are you with running?"].waitForExistence(timeout: 5))
            app.buttons["Back"].doubleTap()
            XCTAssertTrue(app.staticTexts["What are we training for?"].waitForExistence(timeout: 5))
            XCTAssertTrue(goal.isSelected, "The choice must survive the return transition.")
            XCTAssertTrue(app.buttons["Continue"].isEnabled)
            app.terminate()
        }
    }
    @MainActor
    func testEquipmentAndApproachRespondWithoutShiftingChoices() {
        for reduced in [false, true] {
            for (route, firstTitle, secondTitle) in [
                ("--onboarding-equipment", "Dumbbells only", "Bodyweight"),
                ("--onboarding-intensity", "Take your time", "Balanced")
            ] {
                let app = XCUIApplication()
                app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", route]
                    + (reduced ? ["--ui-test-reduce-motion"] : [])
                app.launch()
                if route == "--onboarding-intensity" {
                    let options = app.buttons["onboarding.approach.options"]
                    revealOnboardingControl(options, in: app)
                    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Take your time'")).firstMatch.exists)
                    options.tap()
                }
                let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", firstTitle)).firstMatch
                let second = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", secondTitle)).firstMatch
                revealOnboardingControl(second, in: app)
                XCTAssertTrue(first.isHittable)
                let original = first.frame
                first.tap()
                XCTAssertTrue(first.isSelected)
                XCTAssertEqual(first.frame.minY, original.minY, accuracy: 1)
                second.tap()
                XCTAssertTrue(second.isSelected)
                XCTAssertFalse(first.isSelected)
                XCTAssertEqual(first.frame.minY, original.minY, accuracy: 1)
                if route == "--onboarding-intensity" {
                    app.buttons["Done"].tap()
                } else {
                    let preferences = app.buttons["onboarding.strengthPreferences"]
                    revealOnboardingControl(preferences, in: app)
                    preferences.tap()
                    let split = app.pickerWheels.firstMatch
                    XCTAssertTrue(split.waitForExistence(timeout: 5))
                    split.adjust(toPickerWheelValue: "Upper / lower")
                    app.buttons["Done"].tap()
                    XCTAssertTrue(preferences.label.contains("Upper / lower"))
                }
                XCTAssertTrue(app.buttons["Continue"].isHittable)
                capture(app, name: "\(route)-\(reduced ? "still" : "motion")")
                app.terminate()
            }
        }
    }

    @MainActor
    func testRecentRunningDoesNotAskForFutureMileage() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-volume", "--ui-test-reduce-motion"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your recent running."].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Increase Build up to"].exists)
        let unknown = app.buttons["onboarding.volume.unknown"]
        revealOnboardingControl(unknown, in: app)
        unknown.tap()
        XCTAssertTrue(app.buttons["Per week, Not sure"].exists)
        XCTAssertTrue(app.buttons["Longest run, Not sure"].exists)
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        capture(app, name: "coach-planned-future-mileage")
    }

    @MainActor
    func testWeeklyLimitIsOptionalAndSurvivesClosingTheSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-days", "--ui-test-reduce-motion"]
        app.launch()
        let limits = app.buttons["onboarding.sessionLimits"]
        revealOnboardingControl(limits, in: app)
        limits.tap()
        let disclosure = app.buttons["Weekly distance limit (optional)"]
        revealOnboardingControl(disclosure, in: app)
        disclosure.tap()
        let increase = app.buttons["Increase Weekly limit"]
        revealOnboardingControl(increase, in: app)
        capture(app, name: "weekly-limit-before-edit")
        increase.tap()
        capture(app, name: "weekly-limit-after-edit")
        app.buttons["Done"].tap()
        capture(app, name: "weekly-limit-after-closing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Your weekly distance limit:'")).firstMatch.exists, app.debugDescription)
        limits.tap()
        revealOnboardingControl(disclosure, in: app)
        disclosure.tap()
        let clear = app.buttons["Let the coach choose"].firstMatch
        revealOnboardingControl(clear, in: app)
        clear.tap()
        app.buttons["Done"].tap()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Your weekly distance limit:'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Continue"].isHittable)
    }

    @MainActor
    func testInjurySelectionDoesNotMoveTheControls() {
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-injuries"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            let knee = app.buttons["Knee"]
            let clear = app.buttons["No injuries, I'm all clear"]
            XCTAssertTrue(knee.waitForExistence(timeout: 15))
            XCTAssertTrue(clear.isHittable)
            let originalKnee = knee.frame
            let originalClear = clear.frame
            knee.tap()
            XCTAssertTrue(knee.isSelected)
            XCTAssertEqual(knee.frame.minY, originalKnee.minY, accuracy: 1)
            XCTAssertEqual(clear.frame.minY, originalClear.minY, accuracy: 1)
            app.buttons["Ankle"].tap()
            XCTAssertTrue(knee.isSelected)
            knee.tap()
            app.buttons["Ankle"].tap()
            XCTAssertFalse(knee.isSelected)
            XCTAssertEqual(clear.frame.minY, originalClear.minY, accuracy: 1)
            XCTAssertLessThanOrEqual(clear.frame.maxY, app.buttons["Continue"].frame.minY)
            capture(app, name: reduced ? "injuries-still" : "injuries-motion")
            clear.tap()
            XCTAssertTrue(app.staticTexts["A few personal details."].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testRetiredPermissionStepsResumeAtTheTrainingAssessment() {
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-notifications"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            XCTAssertTrue(app.staticTexts["Here's the approach we recommend."].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["Continue"].isHittable)
            XCTAssertFalse(app.buttons["Turn on reminders"].exists)
            XCTAssertFalse(app.staticTexts["Map your runs"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testGeneratedPlanArrivesAfterBackgroundingInBothMotionModes() {
        for reduced in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-building"]
                + (reduced ? ["--ui-test-reduce-motion"] : [])
            app.launch()
            XCUIDevice.shared.press(.home)
            app.activate()
            let cta = app.buttons["onboarding.reveal.continue"]
            XCTAssertTrue(cta.waitForExistence(timeout: 25))
            XCTAssertTrue(cta.isHittable)
            XCTAssertTrue(app.staticTexts["YOUR FIRST WEEK"].exists)
            XCTAssertFalse(app.staticTexts["Building your plan"].exists)
            capture(app, name: reduced ? "generated-plan-still" : "generated-plan-motion")
            app.terminate()
        }
    }

    @MainActor
    func testReducedMotionWelcomeStillOffersBothDoors() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--reset-auth", "--ui-test-reduce-motion"]
        app.launch()
        let returning = app.buttons["I already have an account"]
        XCTAssertTrue(returning.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Build my plan"].isHittable)
        capture(app, name: "welcome-still")
        returning.tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertTrue(returning.waitForExistence(timeout: 5))
        app.buttons["Build my plan"].tap()
        XCTAssertTrue(app.staticTexts["Let's make it yours."].waitForExistence(timeout: 10))
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}


extension OnboardingMotionUITests {
    @MainActor
    func testTrainingBackgroundAndBenchmarkAreIndependent() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-experience", "--ui-test-reduce-motion"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Where are you with running?"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        capture(app, name: "running-background")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Recent race or timed effort'")).firstMatch
        revealOnboardingControl(result, in: app)
        result.tap()
        XCTAssertTrue(app.buttons["Marathon"].waitForExistence(timeout: 5))
        app.buttons["Marathon"].tap()
        XCTAssertFalse(app.buttons["onboarding.saveBenchmark"].isEnabled,
                       "Choosing a distance must never save its placeholder time")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        let background = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Running regularly'")).firstMatch
        // Dismissing the optional sheet retains the question's scroll position.
        for _ in 0..<5 where !background.isHittable { app.scrollViews.firstMatch.swipeDown() }
        revealOnboardingControl(background, in: app)
        background.tap()
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        revealOnboardingControl(result, in: app)
        result.tap()
        app.buttons["5K"].tap()
        app.buttons["onboarding.benchmarkTime"].tap()
        let time = app.textFields["onboarding.benchmarkTime"]
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        time.typeText("22:30")
        XCTAssertTrue(app.buttons["onboarding.saveBenchmark"].isEnabled)
        time.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        capture(app, name: "benchmark-after-clearing")
        XCTAssertFalse(app.buttons["onboarding.saveBenchmark"].isEnabled)
        time.typeText("22:30")
        app.toolbars.buttons["Done"].tap()
        capture(app, name: "benchmark-confirmation")
        XCTAssertTrue(app.buttons["onboarding.saveBenchmark"].isEnabled)
        app.buttons["onboarding.saveBenchmark"].tap()
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        capture(app, name: "running-background-with-result")
    }
}

/// Uses real keyboard and scroll interactions on compact and large iPhone destinations.
/// Large text uses the system preference, including the app's existing accessibility-size cap.
final class NativePhoneOnboardingUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    private func launch(_ arguments: [String], largeText: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--reset-auth", "--ui-test-reduce-motion"] + arguments
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        revealOnboardingControl(element, in: app)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testGoalAndBackNavigationAtBothTextSizes() {
        for large in [false, true] {
            let app = launch(["--onboarding", "--onboarding-guest", "--onboarding-goal"], largeText: large)
            let goal = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Stay consistent'")).firstMatch
            reveal(goal, in: app)
            goal.tap()
            app.buttons["Continue"].tap()
            XCTAssertTrue(app.staticTexts["Where are you with running?"].waitForExistence(timeout: 10))
            app.buttons["Back"].tap()
            reveal(goal, in: app)
            XCTAssertTrue(goal.isSelected)
            capture(app, "goal-back-\(large ? "large" : "standard")")
            app.terminate()
        }
    }

    @MainActor
    func testDenseQuestionsRemainScrollableWithLargeText() {
        let app = launch(["--onboarding", "--onboarding-guest", "--onboarding-injuries"])
        let clear = app.buttons["No injuries, I'm all clear"]
        reveal(clear, in: app)
        XCTAssertLessThanOrEqual(clear.frame.maxY, app.buttons["Continue"].frame.minY + 1)
        capture(app, "large-text-last-injury-choice")
        clear.tap()
        XCTAssertTrue(app.staticTexts["A few personal details."].waitForExistence(timeout: 5))
        app.terminate()

        let goalApp = launch(["--onboarding", "--onboarding-guest", "--onboarding-goal"])
        let goal = goalApp.buttons.matching(NSPredicate(format: "label CONTAINS 'Become a stronger runner'")).firstMatch
        reveal(goal, in: goalApp)
        goal.tap()
        XCTAssertTrue(goal.isSelected)
        XCTAssertTrue(goalApp.buttons["Continue"].isHittable)
        capture(goalApp, "large-text-goal-choice")
        goalApp.buttons["Continue"].tap()
        XCTAssertTrue(goalApp.staticTexts["Where are you with running?"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPersonalDetailsFitAndRemainEditableWithLargeText() {
        let app = launch(["--onboarding", "--onboarding-guest", "--onboarding-metrics"])
        let heading = app.staticTexts["A few personal details."]
        XCTAssertTrue(heading.waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(heading.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(heading.frame.maxX, app.frame.maxX)
        XCTAssertTrue(app.buttons["Back"].isHittable)
        let female = app.buttons["Female"]
        reveal(female, in: app)
        female.tap()
        for metric in ["Age", "Height", "Weight"] {
            let plus = app.buttons["Increase \(metric)"]
            reveal(plus, in: app)
            XCTAssertGreaterThanOrEqual(plus.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(plus.frame.maxX, app.frame.maxX)
            plus.tap()
            capture(app, "large-text-personal-\(metric.lowercased())")
        }
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Let's shape your training week."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOversizedHeightInputDoesNotCrashAndCanBeCorrected() {
        let app = launch(["--onboarding", "--onboarding-guest", "--onboarding-metrics"], largeText: false)
        let imperial = app.buttons["ft·in"]
        reveal(imperial, in: app)
        imperial.tap()
        let height = app.buttons["onboarding.metric.height"]
        reveal(height, in: app)
        height.tap()
        let field = app.textFields["onboarding.metric.height"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("9000000000000000000 10")
        app.toolbars.buttons["Done"].tap()
        XCTAssertTrue(height.waitForExistence(timeout: 5))
        XCTAssertTrue(height.label.contains("7′6″"))
        reveal(height, in: app)
        height.tap()
        field.typeText("5 10")
        app.toolbars.buttons["Done"].tap()
        XCTAssertTrue(height.label.contains("5′10″"))
    }

    @MainActor
    func testInteractiveWeekAndPersonalBriefWithLargeText() {
        let app = launch(["--onboarding", "--onboarding-guest", "--onboarding-days"])
        XCTAssertTrue(app.staticTexts["Let's shape your training week."].waitForExistence(timeout: 20))
        let monday = app.buttons["Monday"]
        reveal(monday, in: app)
        XCTAssertGreaterThanOrEqual(monday.frame.width, 44)
        monday.tap()
        XCTAssertTrue(monday.isSelected)
        reveal(app.buttons["onboarding.sessionLimits"], in: app)
        app.buttons["onboarding.sessionLimits"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        reveal(monday, in: app)
        XCTAssertTrue(monday.isSelected)
        capture(app, "large-text-interactive-week")
        app.terminate()

        let brief = launch(["--onboarding", "--onboarding-guest", "--onboarding-intensity"])
        let assessment = brief.buttons["View training assessment"]
        reveal(assessment, in: brief)
        capture(brief, "large-text-personal-brief")
        assessment.tap()
        XCTAssertTrue(brief.staticTexts["Your training assessment"].waitForExistence(timeout: 5))
        XCTAssertTrue(brief.buttons["Done"].isHittable)
        brief.buttons["Done"].tap()
        let approach = brief.buttons["onboarding.approach.options"]
        reveal(approach, in: brief)
        XCTAssertTrue(approach.isHittable)
        XCTAssertTrue(brief.buttons["Continue"].isHittable)
    }

    @MainActor
    func testBenchmarkKeyboardCommitsWithLargeText() {
        let app = launch(["--onboarding", "--onboarding-guest", "--onboarding-experience"])
        let background = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Running regularly'")).firstMatch
        reveal(background, in: app); background.tap()
        XCTAssertTrue(background.isSelected)
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Recent race or timed effort'")).firstMatch
        reveal(result, in: app); result.tap()
        let distance = app.buttons["onboarding.benchmarkDistance"]
        reveal(distance, in: app); distance.tap()
        app.buttons["Marathon"].tap()
        XCTAssertTrue(distance.label.contains("Marathon"))
        capture(app, "large-text-benchmark-distance")
        distance.tap()
        app.buttons["5K"].tap()
        let value = app.buttons["onboarding.benchmarkTime"]
        reveal(value, in: app); value.tap()
        let input = app.textFields["onboarding.benchmarkTime"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("22:30")
        let done = app.toolbars.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
        capture(app, "large-text-benchmark-keyboard")
        done.tap()
        let save = app.buttons["onboarding.saveBenchmark"]
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled)
        capture(app, "large-text-benchmark-save")
        save.tap()
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue"].isEnabled && app.buttons["Continue"].isHittable)
        capture(app, "large-text-saved-benchmark")
    }

    @MainActor
    func testWelcomeAndGeneratedRevealWithLargeText() {
        let app = launch([])
        let start = app.buttons["welcome.gallery.start"]
        reveal(start, in: app)
        capture(app, "large-text-welcome")
        start.tap()
        XCTAssertTrue(app.staticTexts["Let's make it yours."].waitForExistence(timeout: 10))
        app.terminate()

        let revealApp = launch(["--onboarding", "--onboarding-guest", "--onboarding-building", "--review-no-ask"])
        let next = revealApp.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 30))
        reveal(next, in: revealApp)
        capture(revealApp, "large-text-plan-reveal")
        next.tap()
        let review = revealApp.buttons["onboarding.review.continue"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.isHittable)
        capture(revealApp, "large-text-review")
        review.tap()
        crossPermissionBeats(revealApp)
        XCTAssertTrue(revealApp.buttons["Restore"].waitForExistence(timeout: 15))
        // The page remains underneath the full-screen checkout; it must not receive input.
        XCTAssertFalse(revealApp.buttons["onboarding.review.continue"].isHittable)
        capture(revealApp, "large-text-checkout")
    }

    @MainActor
    func testRetiredPermissionsResumeWithAccessibleControls() {
        for argument in ["--onboarding-health", "--onboarding-notifications"] {
            let app = launch(["--onboarding", "--onboarding-guest", argument])
            let next = app.buttons["Continue"]
            XCTAssertTrue(next.waitForExistence(timeout: 15) && next.isHittable)
            XCTAssertTrue(app.staticTexts["Here's the approach we recommend."].exists)
            XCTAssertFalse(app.buttons["Turn on reminders"].exists)
            app.terminate()
        }
    }

}

extension OnboardingMotionUITests {
    @MainActor
    func testRunnerTimeLimitsAreOptionalAndAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--onboarding-session-runner", "--ui-test-reduce-motion"]
        app.launch()
        let limits = app.buttons["onboarding.sessionLimits"]
        XCTAssertTrue(limits.waitForExistence(timeout: 20))
        limits.tap()
        XCTAssertTrue(app.staticTexts["How much time do you have?"].waitForExistence(timeout: 5))
        let limit = app.switches["Keep regular runs within this time"]
        XCTAssertTrue(limit.exists)
        XCTAssertEqual(limit.value as? String, "0")
        revealOnboardingControl(limit, in: app)
        capture(app, name: "regular-run-limit-before-tap")
        limit.tap()
        XCTAssertEqual(limit.value as? String, "1")
        let longRun = app.buttons["Long-run time limit (optional)"]
        revealOnboardingControl(longRun, in: app)
        longRun.tap()
        capture(app, name: "runner-time-limits")
        app.buttons["Done"].tap()
        let next = app.buttons["Continue"]
        XCTAssertTrue(next.isEnabled && next.isHittable)
    }
}
