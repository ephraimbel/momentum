import XCTest

/// The front door (App Review path). Since 2026-07-27 the welcome asks for no account at all:
/// "Build my plan" goes straight into setup, and the account is offered on the last beat of
/// onboarding. This test pins the two things that must never regress:
///
/// 1. **Nobody is blocked at launch.** The primary CTA enters the app with no credentials and no
///    network — the reason the sign-in screen was moved off the entry in the first place.
/// 2. **The returning athlete still has a door**, and it still shows every option — Sign in with
///    Apple included, which App Store 4.8 requires beside Google. This assertion is the only place
///    that rule is encoded; do not delete it.
@MainActor
final class GuestEntryUITests: XCTestCase {

    func testWelcomeEntersTheAppWithoutAnAccount() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Start with a fresh local store so this test always exercises the first-run welcome.
        app.launchArguments = ["--reset-store", "--reset-auth"]
        app.launch()

        // The welcome hero. "Build my plan" on a device with no training; "Continue as …" when a
        // profile is already here (signed out, or an Apple credential was revoked).
        let getStarted = app.buttons["Build my plan"]
        let returning = app.buttons["I already have an account"]
        XCTAssertTrue(returning.waitForExistence(timeout: 10), "reset-auth should land on the welcome")
        attach("1-welcome")

        // The account page must be reachable WITHOUT walking setup — the reinstall path.
        returning.tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 5), "email box should be on the account page")
        XCTAssertTrue(app.appleSignInButton.exists, "SIWA must accompany third-party login (4.8)")
        XCTAssertTrue(app.buttons["Continue with Google"].exists)
        XCTAssertTrue(app.buttons["Continue without an account"].exists, "the guest door stays open")
        attach("2-account-page")

        // Back to the hero, then in through the front door.
        app.buttons["Back"].tap()
        XCTAssertTrue(returning.waitForExistence(timeout: 5), "Back should return to the welcome")

        let fresh = getStarted.exists
        (fresh ? getStarted : app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue as'")).firstMatch).tap()

        // Entered with no credentials: onboarding on a fresh device, tabs on a lived-in one.
        let onboarding = app.staticTexts["Let's make it yours."]
        let tabs = app.tabBars.firstMatch
        // We already know which door was rendered. Waiting for the impossible destination first
        // made the lived-in path burn 15 seconds of repeated accessibility snapshots before it
        // even checked the tab bar, which could get the UI-test runner killed under load.
        let entered = fresh
            ? onboarding.waitForExistence(timeout: 15)
            : tabs.waitForExistence(timeout: 15)
        XCTAssertTrue(entered, "the primary CTA must enter the app with no account")
        if fresh {
            XCTAssertTrue(onboarding.exists, "with no profile, Build my plan goes straight into setup")
        }
        attach("3-entered")

        // Relaunch WITHOUT reset — the local session must persist, or a backgrounded athlete is
        // dumped back on the welcome and loses their place in setup.
        app.terminate()
        app.launchArguments = []
        app.launch()
        // Prove the positive destination instead of polling for an element that should stay
        // absent. On a busy simulator, XCTest's repeated accessibility debug snapshots for an
        // expected absence can outlive the requested timeout and get the runner watchdog-killed.
        let remainedInside = fresh
            ? app.staticTexts["Let's make it yours."].waitForExistence(timeout: 10)
            : app.tabBars.firstMatch.waitForExistence(timeout: 10)
        XCTAssertTrue(remainedInside, "the local session must survive relaunch")
        XCTAssertFalse(app.buttons["I already have an account"].exists,
                       "relaunch must not return an entered athlete to the welcome")
        attach("4-relaunch-still-in")
    }

    /// The hand-off the reorder is actually about: the paywall no longer ends onboarding — the
    /// account beat does. Driven as a real guest (`--onboarding-guest`), because a signed-in
    /// athlete correctly self-skips the beat and would prove nothing.
    func testAccountBeatFollowsThePaywallAndIsSkippable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // --debug-free: a sim left dev-unlocked by an earlier --debug-pro would sail past the paywall.
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-guest", "--onboarding-reveal", "--debug-free"]
        app.launch()
        let revealCTA = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(revealCTA.waitForExistence(timeout: 20), "should land on the plan reveal")
        attach("beat-1-reveal")
        revealCTA.tap()

        XCTAssertTrue(app.staticTexts["YOUR GOAL"].waitForExistence(timeout: 10))
        attach("beat-2-paywall")
        let trialCTA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Unlock my plan' OR label BEGINSWITH 'Continue ·' OR label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(trialCTA.waitForExistence(timeout: 10), "the checkout page should follow the reminder page")
        XCTAssertFalse(app.buttons["Close"].exists, "the hard-wall checkout must not carry an X")
        trialCTA.tap()

        // …and subscribing lands on the account, not in the app. This is the whole change.
        let accountBeat = app.staticTexts["Save your progress"]
        XCTAssertTrue(accountBeat.waitForExistence(timeout: 10),
                      "subscribing must hand off to the account beat, not complete onboarding")
        XCTAssertTrue(app.appleSignInButton.exists, "SIWA must accompany third-party login (4.8)")
        XCTAssertTrue(app.buttons["Continue with Google"].exists)
        attach("beat-3-account")

        // Skippable, and skipping enters the app as a guest — never a wall.
        let skip = app.buttons["Not now"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "the account must be offered, never required")
        skip.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15),
                      "declining the account still enters the app")
        attach("beat-4-entered")
    }

    /// The whole point of moving the account to the end: what the athlete told us during setup has
    /// to survive into the app. Walks the real guest flow with a typed name and checks it lands on
    /// the profile — a blank `displayName` renders as "Athlete", which is the regression this pins.
    func testOnboardingAnswersSurviveIntoTheApp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // `--reset-store` makes the precondition self-sufficient. This test needs a device with NO
        // local profile: it taps "Build my plan" and expects setup. `--reset-auth` only clears the
        // stored identity and leaves the SwiftData profile behind, so after any sibling test (or a
        // manual --seed-demo launch) the app skipped setup entirely and the guard tripped. With the
        // wipe the walk now reliably starts in onboarding on any device.
        app.launchArguments = ["--reset-store", "--reset-auth", "--debug-free", "--uitest-password"]
        app.launch()

        let getStarted = app.buttons["Build my plan"]
        guard getStarted.waitForExistence(timeout: 10) else {
            return XCTFail("needs a clean install (no local profile) — uninstall the app first")
        }
        getStarted.tap()

        XCTAssertTrue(app.staticTexts["Let's make it yours."].waitForExistence(timeout: 10))
        var enteredName = false

        // Walk generically as far as the PAYWALL: answer the one step that demands a pick, decline
        // every opt-in, Continue through everything else. The loop has to stop here — past the
        // paywall the account beat's "Not now" would be skipped mid-crossfade before it could be
        // checked. (No rating beat sits in here any more — it was removed 2026-08-22.)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The hard paywall's checkout CTA is the sentinel now that it renders no Close. It's also
        // safe as a loop guard: none of the generic taps below match "Start my …", so the walker
        // can't buy — pages one and two of the flow ("Try now", "Continue for free") sell without
        // transacting, so walking through them is free.
        let paywallCTA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Unlock my plan' OR label BEGINSWITH 'Continue ·' OR label BEGINSWITH 'Start my'")).firstMatch
        // The health step's Continue raises the real HealthKit sheet (5.1.1(iv): no skip button
        // anymore). iOS 26 hosts this sheet in HealthPrivacyService rather than Health.app.
        let healthApp = XCUIApplication(bundleIdentifier: "com.apple.HealthPrivacyService")
        // Never let a system-owned sheet turn this release gate into an hour-long accessibility
        // poll. In-app actions are checked first; querying an absent cross-process Health element
        // can itself take three seconds on iOS 26, so touch that process only while it is foreground.
        let walkDeadline = Date().addingTimeInterval(120)
        var advancedSteps = 0
        var healthCategoriesEnabled = false
        while Date() < walkDeadline, advancedSteps < 40 {
            if paywallCTA.exists { break }

            let nameField = app.textFields["Your name"]
            if !enteredName, nameField.exists, nameField.isHittable {
                nameField.tap()
                nameField.typeText("Maya\n")
                let username = app.textFields["Handle"]
                username.tap()
                username.press(forDuration: 1)
                if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap() }
                // Replace the name suggestion with an explicit test-only username.
                let oldValue = username.value as? String ?? ""
                username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count)
                                  + "maya_qa_\(UUID().uuidString.prefix(8).lowercased())\n")
                enteredName = true
                attach("walk-personal-details")
            }

            if app.staticTexts["What supports your running?"].exists, !app.buttons["Continue"].isEnabled {
                app.staticTexts["Run"].firstMatch.tap()
            }
            // Goal is gated too (2026-08-28): pick the plainest one so the walk isn't goal-shaped.
            if app.staticTexts["What are we training for?"].exists, !app.buttons["Continue"].isEnabled {
                app.staticTexts["Stay consistent"].firstMatch.tap()
            }
            let looksGreat = app.buttons["onboarding.reveal.continue"]
            if app.staticTexts["Tell us about your running."].exists, !app.buttons["Continue"].isEnabled {
                app.staticTexts["Easy jogger"].firstMatch.tap()
            }
            let maybeLater = app.buttons["Maybe later"]
            let notNow = app.buttons["Not now"]
            // The tour CTA is a STORE fact: "Try now" while eligible, "Continue" otherwise.
            let tryNow = app.buttons.matching(NSPredicate(format: "label == 'Try now' OR label == 'Continue'")).firstMatch // paywall tour
            // "Continue" is NOT unique once the paywall cover is up: the primer's own Continue
            // stays in the hierarchy underneath it, `firstMatch` picks that covered one, and a
            // walker keyed on `firstMatch.isHittable` sleeps forever (found 2026-08-28 after a 1257s
            // timeout). Take the first Continue that is actually hittable, wherever it lives.
            let liveContinue = app.buttons.matching(identifier: "Continue").allElementsBoundByIndex
                .first { $0.isHittable && $0.isEnabled }
            let inAppAction = liveContinue
                ?? [looksGreat, maybeLater, notNow, tryNow].first { $0.exists && $0.isHittable }
            if let inAppAction {
                inAppAction.tap()
                advancedSteps += 1
                usleep(300_000)
                continue
            }

            // Notifications and location are SpringBoard alerts. Check for one alert before
            // probing each possible label; absent cross-process elements are the expensive case.
            var handledSystemSheet = false
            if springboard.alerts.firstMatch.exists {
                for label in ["Allow While Using App", "Allow Once", "Allow", "OK"] {
                    let allow = springboard.buttons[label]
                    if allow.exists && allow.isHittable {
                        allow.tap()
                        handledSystemSheet = true
                        break
                    }
                }
            }
            if !handledSystemSheet, healthApp.state == .runningForeground {
                handledSystemSheet = grantHealthSheet(
                    healthApp,
                    categoriesEnabled: &healthCategoriesEnabled
                )
            } else if healthApp.state != .runningForeground {
                healthCategoriesEnabled = false
            }
            if handledSystemSheet { advancedSteps += 1 }
            else { usleep(300_000) } // building beat / animating in
        }
        let reachedPaywall = paywallCTA.waitForExistence(timeout: 5)
        let visibleHeadings = app.staticTexts.allElementsBoundByIndex.prefix(8).map(\.label)
        XCTAssertTrue(
            reachedPaywall,
            "the walk should reach the paywall within 120s; advanced=\(advancedSteps), "
                + "appState=\(app.state.rawValue), healthState=\(healthApp.state.rawValue), "
                + "visible=\(visibleHeadings)"
        )
        guard reachedPaywall else { return }
        paywallCTA.tap()

        let accountBeat = app.staticTexts["Save your progress"]
        XCTAssertTrue(accountBeat.waitForExistence(timeout: 20), "the paywall should hand off to the account beat")
        attach("walk-2-account-beat")

        // Decline the account — everything built as a guest must still be there.
        app.buttons["Not now"].tap()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 20), "declining the account still enters the app")

        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(app.staticTexts["Maya"].waitForExistence(timeout: 15),
                      "the name given during setup must reach the profile, not fall back to 'Athlete'")
        XCTAssertFalse(app.staticTexts["Athlete"].exists, "'Athlete' means the profile lost its name")
        attach("walk-3-profile")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @discardableResult
    private func grantHealthSheet(_ healthApp: XCUIApplication,
                                  categoriesEnabled: inout Bool) -> Bool {
        var interacted = false
        if !categoriesEnabled {
            let allCategories = healthApp.cells["UIA.Health.AuthSheet.AllCategoryButton"]
            if allCategories.exists && allCategories.isHittable {
                allCategories.tap()
                categoriesEnabled = true
                interacted = true
            } else {
                let allText = healthApp.staticTexts["Turn On All"]
                if allText.exists && allText.isHittable {
                    allText.tap()
                    categoriesEnabled = true
                    interacted = true
                }
            }
            if !categoriesEnabled {
                for label in ["Turn On All", "Turn On All Categories", "Enable All"] {
                    let control = healthApp.switches[label].exists
                        ? healthApp.switches[label] : healthApp.buttons[label]
                    if control.exists && control.isHittable {
                        control.tap()
                        categoriesEnabled = true
                        interacted = true
                        break
                    }
                }
            }
        }
        let allow = healthApp.buttons["Allow"]
        guard allow.exists && allow.isHittable else { return interacted }
        allow.tap()
        categoriesEnabled = false
        return true
    }
}
