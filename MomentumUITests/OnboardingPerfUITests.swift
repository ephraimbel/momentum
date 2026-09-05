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
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--debug-free", "--onboarding-goal"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch(); app.tap()
        XCTAssertTrue(app.staticTexts["What are we training for?"].waitForExistence(timeout: 20))
        var advanced = 0
        var stalls: [String] = []
        for i in 0..<16 {
            // Gated steps: answer them so the walk can continue.
            if app.staticTexts["What supports your running?"].exists, !app.buttons["Continue"].isEnabled {
                app.staticTexts["Run"].firstMatch.tap()
            }
            if app.staticTexts["What are we training for?"].exists, !app.buttons["Continue"].isEnabled {
                app.staticTexts["Stay consistent"].firstMatch.tap()
            }
            if app.staticTexts["Tell us about your running."].exists, !app.buttons["Continue"].isEnabled {
                app.staticTexts["Easy jogger"].firstMatch.tap()
            }
            let heading = app.staticTexts.firstMatch.label
            guard let cont = app.buttons.matching(identifier: "Continue").allElementsBoundByIndex
                .first(where: { $0.isHittable && $0.isEnabled }) else { break }
            // The permission beats hand off to a SYSTEM sheet, so their tap-to-next-screen time
            // is iOS's, not ours — budget for the dialog rather than calling it a stall.
            let systemPrompt = heading.contains("recovery") || heading.contains("nudge")
                || heading.contains("Map your runs")
            let budget: TimeInterval = systemPrompt ? 12 : 3
            let t0 = Date()
            cont.tap()
            let settled = app.buttons.matching(identifier: "Continue").allElementsBoundByIndex
                .contains { $0.isHittable } || app.buttons["Turn on reminders"].waitForExistence(timeout: budget)
            let dt = Date().timeIntervalSince(t0)
            // The questions end at the build beat, which is a deliberate animated moment with no
            // Continue on it — reaching it means the walk finished, not that a step stalled.
            // (2026-08-30: the walk grew past the last question when `.session` became universal,
            // and the build screen's own animation reported as a 3.39 s stall on the step before
            // it. Budgeting for it would have hidden a real stall there later.)
            if app.staticTexts["Building your plan"].exists { advanced += 1; break }
            if !settled || dt > budget { stalls.append("step \(i) (\(heading)) took \(String(format: "%.2f", dt))s") }
            advanced += 1
            usleep(500_000)   // just past the flow's own 0.45s advance debounce
        }
        XCTAssertTrue(stalls.isEmpty, "steps stalled: \(stalls.joined(separator: "; "))")
        XCTAssertGreaterThan(advanced, 8, "the walk stopped after only \(advanced) steps")
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
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["How much time do you have?"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
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
    func testPrimaryQuestionsFitWithoutScrolling() {
        let app = XCUIApplication()
        let pages: [(String, String)] = [
            ("--onboarding-goal", "Become a stronger runner"),
            ("--onboarding-race", "Target finish time"),
            ("--onboarding-experience", "Recent running result"),
            ("--onboarding-experience-hybrid", "Lifting experience"),
            ("--onboarding-volume", "Increase Build up to"),
            ("--onboarding-metrics", "Increase Weight"),
            ("--onboarding-musclefocus", "Core"),
            ("--onboarding-injuries", "No injuries, I'm all clear"),
            ("--onboarding-equipment", "Lifting split"),
            ("--onboarding-session", "75+ min"),
            ("--onboarding-intensity", "Podium"),
            ("--onboarding-intensity-short", "Podium")
        ]
        for (argument, label) in pages {
            app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", argument, "--ui-test-reduce-motion"]
            app.launch()
            let choice = argument == "--onboarding-equipment" ? app.buttons["onboarding.liftingSplit"]
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
            XCTAssertTrue(choice.isHittable, "\(label) requires scrolling")
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
    func testNameAndUsernameShareTheFirstPageAndSurviveBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--onboarding", "--onboarding-guest", "--ui-test-reduce-motion"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Let's make it yours."].waitForExistence(timeout: 15))
        let name = app.textFields["Your name"]
        let username = app.textFields["Handle"]
        XCTAssertTrue(name.isHittable && username.isHittable)
        name.tap()
        name.typeText("Alex Mora\n")
        username.tap()
        let suggested = username.value as? String ?? ""
        let custom = "alex_qa_\(UUID().uuidString.prefix(8).lowercased())"
        username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: suggested.count) + custom + "\n")
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["What are we training for?"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Alex Mora")
        XCTAssertEqual(username.value as? String, custom)
    }

}
