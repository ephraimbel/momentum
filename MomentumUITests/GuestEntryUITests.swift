import XCTest

/// The front door (App Review path). Since 2026-07-27 the welcome asks for no account at all:
/// "Get started" goes straight into setup, and the account is offered on the last beat of
/// onboarding. This test pins the two things that must never regress:
///
/// 1. **Nobody is blocked at launch.** The primary CTA enters the app with no credentials and no
///    network — the reason the sign-in screen was moved off the entry in the first place.
/// 2. **The returning athlete still has a door**, and it still shows every option — Sign in with
///    Apple included, which App Store 4.8 requires beside Google. This assertion is the only place
///    that rule is encoded; do not delete it.
final class GuestEntryUITests: XCTestCase {

    func testWelcomeEntersTheAppWithoutAnAccount() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Clears the stored identity only — a sim that has run --seed-demo keeps its profile, so
        // the welcome may render either variant. Both are asserted below.
        app.launchArguments = ["--reset-auth"]
        app.launch()

        // The welcome hero. "Get started" on a device with no training; "Continue as …" when a
        // profile is already here (signed out, or an Apple credential was revoked).
        let getStarted = app.buttons["Get started"]
        let returning = app.buttons["I already have an account"]
        XCTAssertTrue(returning.waitForExistence(timeout: 10), "reset-auth should land on the welcome")
        attach("1-welcome")

        // The account page must be reachable WITHOUT walking setup — the reinstall path.
        returning.tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 5), "email box should be on the account page")
        XCTAssertTrue(app.buttons["Sign in with Apple"].exists, "SIWA must accompany third-party login (4.8)")
        XCTAssertTrue(app.buttons["Continue with Google"].exists)
        XCTAssertTrue(app.buttons["Continue without an account"].exists, "the guest door stays open")
        attach("2-account-page")

        // Back to the hero, then in through the front door.
        app.buttons["Back"].tap()
        XCTAssertTrue(returning.waitForExistence(timeout: 5), "Back should return to the welcome")

        let fresh = getStarted.exists
        (fresh ? getStarted : app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue as'")).firstMatch).tap()

        // Entered with no credentials: onboarding on a fresh device, tabs on a lived-in one.
        let onboarding = app.staticTexts["What should we call you?"]
        let tabs = app.tabBars.firstMatch
        let entered = onboarding.waitForExistence(timeout: 15) || tabs.waitForExistence(timeout: 15)
        XCTAssertTrue(entered, "the primary CTA must enter the app with no account")
        if fresh {
            XCTAssertTrue(onboarding.exists, "with no profile, Get started goes straight into setup")
        }
        attach("3-entered")

        // Relaunch WITHOUT reset — the local session must persist, or a backgrounded athlete is
        // dumped back on the welcome and loses their place in setup.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertFalse(app.buttons["I already have an account"].waitForExistence(timeout: 6),
                       "the local session must survive relaunch")
        attach("4-relaunch-still-in")
    }

    /// The hand-off the reorder is actually about: the paywall no longer ends onboarding — the
    /// account beat does. Driven as a real guest (`--onboarding-guest`), because a signed-in
    /// athlete correctly self-skips the beat and would prove nothing.
    func testAccountBeatFollowsThePaywallAndIsSkippable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // --debug-free: a sim left dev-unlocked by an earlier --debug-pro would sail past the paywall.
        app.launchArguments = ["--onboarding", "--onboarding-guest", "--onboarding-rate", "--debug-free"]
        app.launch()

        // The rating beat, the last step before the paywall.
        let notNow = app.buttons["Not now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 15), "should land on the rating beat")
        attach("beat-1-rate")
        notNow.tap()

        // The paywall — a two-page flow since 2026-08-05 (device tour, then checkout), SOFT since
        // 2026-08-06: the checkout page's X skips it (the tour carries no X). This test takes the
        // purchase path; the DEBUG seam grants locally, which is exactly the entitlement flip
        // under test.
        let tryNow = app.buttons["Try now"]
        XCTAssertTrue(tryNow.waitForExistence(timeout: 10), "the paywall should follow the rating beat")
        XCTAssertFalse(app.buttons["Close"].exists, "the tour page carries no X — checkout-only")
        attach("beat-2-paywall")
        tryNow.tap()
        let trialCTA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(trialCTA.waitForExistence(timeout: 10), "the checkout page should follow the reminder page")
        XCTAssertTrue(app.buttons["Close"].exists, "the checkout page must offer the soft gate's X")
        trialCTA.tap()

        // …and subscribing lands on the account, not in the app. This is the whole change.
        let accountBeat = app.staticTexts["Save your progress"]
        XCTAssertTrue(accountBeat.waitForExistence(timeout: 10),
                      "dismissing the paywall must hand off to the account beat, not complete onboarding")
        XCTAssertTrue(app.buttons["Sign in with Apple"].exists, "SIWA must accompany third-party login (4.8)")
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
        // local profile: it taps "Get started" and expects setup. `--reset-auth` only clears the
        // stored identity and leaves the SwiftData profile behind, so after any sibling test (or a
        // manual --seed-demo launch) the app skipped setup entirely and the guard tripped. With the
        // wipe the walk now reliably starts in onboarding on any device.
        //
        // ⚠️ STILL FAILING, and not because of the precondition. The walker gets through the name,
        // "What do you want to do?" and ~8 more Continues, then stalls dead around the HealthKit
        // step: since the 5.1.1(iv) fix that Continue raises the real permission sheet from
        // com.apple.Health with no skip, and the `healthApp` handling below never dismisses it on
        // current iOS. The remaining ~70 iterations are the `sleep(1)` fallback, which is where the
        // ~21 minute runtime comes from before the paywall assert fails. Fixing that means getting
        // the system sheet automation right, not touching the app. Known burn-down item.
        app.launchArguments = ["--reset-store", "--reset-auth", "--debug-free", "--uitest-password"]
        app.launch()

        let getStarted = app.buttons["Get started"]
        guard getStarted.waitForExistence(timeout: 10) else {
            return XCTFail("needs a clean install (no local profile) — uninstall the app first")
        }
        getStarted.tap()

        // Name step — the answer this test is about.
        let nameField = app.textFields["Your name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "setup should open on the name question")
        nameField.tap()
        nameField.typeText("Maya")
        attach("walk-1-name")

        // Walk generically as far as the PAYWALL: answer the one step that demands a pick, decline
        // every opt-in, Continue through everything else. The loop has to stop here — the rating
        // beat and the account beat both label their skip "Not now", so past this point that query
        // is ambiguous and would skip the account beat mid-crossfade before it could be checked.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The hard paywall's checkout CTA is the sentinel now that it renders no Close. It's also
        // safe as a loop guard: none of the generic taps below match "Start my …", so the walker
        // can't buy — pages one and two of the flow ("Try now", "Continue for free") sell without
        // transacting, so walking through them is free.
        let paywallCTA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start my'")).firstMatch
        // The health step's Continue raises the real HealthKit sheet (5.1.1(iv): no skip button
        // anymore) — it presents from com.apple.Health, so drive that process directly.
        let healthApp = XCUIApplication(bundleIdentifier: "com.apple.Health")
        for _ in 0..<80 {
            if paywallCTA.exists { break }
            // System permission alerts (notifications, location) block everything behind them.
            for allow in [springboard.buttons["Don't Allow"], springboard.buttons["Allow"]]
            where allow.exists && allow.isHittable { allow.tap() }
            for label in ["Turn On All", "Turn On All Categories", "Enable All"] {
                let sw = healthApp.switches[label]
                if sw.exists && sw.isHittable { sw.tap() }
                let btn = healthApp.buttons[label]
                if btn.exists && btn.isHittable { btn.tap() }
            }
            let allowHealth = healthApp.buttons["Allow"]
            if allowHealth.exists && allowHealth.isHittable { allowHealth.tap() }

            if app.staticTexts["What do you want to do?"].exists, !app.buttons["Continue"].isEnabled {
                app.staticTexts["Run"].firstMatch.tap()
            }
            let cont = app.buttons["Continue"]
            let looksGreat = app.buttons["This looks great"]
            let maybeLater = app.buttons["Maybe later"]
            let notNow = app.buttons["Not now"]
            let tryNow = app.buttons["Try now"]                             // paywall flow, the tour page
            if cont.exists && cont.isHittable && cont.isEnabled { cont.tap() }
            else if looksGreat.exists && looksGreat.isHittable { looksGreat.tap() }
            else if maybeLater.exists && maybeLater.isHittable { maybeLater.tap() }
            else if notNow.exists && notNow.isHittable { notNow.tap() }     // rating beat
            else if tryNow.exists && tryNow.isHittable { tryNow.tap() }
            else { sleep(1) }                                               // building beat / animating in
        }
        XCTAssertTrue(paywallCTA.waitForExistence(timeout: 30), "the walk should reach the paywall")
        paywallCTA.tap()

        let accountBeat = app.staticTexts["Save your progress"]
        XCTAssertTrue(accountBeat.waitForExistence(timeout: 20), "the paywall should hand off to the account beat")
        // Let the rating beat finish animating out, or "Not now" resolves ambiguously.
        let ratingTitle = app.staticTexts["Your plan is ready"]
        for _ in 0..<20 where ratingTitle.exists { usleep(200_000) }
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
}
