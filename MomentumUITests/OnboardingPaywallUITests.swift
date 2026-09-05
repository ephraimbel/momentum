import XCTest

/// The onboarding paywall is hard: the last beat offers the annual trial, a weekly subscription,
/// and Restore, with no close or swipe bypass. Verifies the gate survives a force-quit, the App
/// Store outage escape remains available, and a trial grants-and-advances. Uses the local purchase
/// seam (no RevenueCat in DEBUG), so the trial tap exercises the real entitlement hand-off.
final class OnboardingPaywallUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// Enters at the plan reveal. Notifications and location now happen before generation; the
    /// conversion hand-off under test is reveal → checkout → account.
    private func launchToPaywall(_ app: XCUIApplication) {
        // Seeded profile (the flow needs one) + forced-free entitlement so the paywall actually
        // shows — `--debug-free` is read before `--seed-demo`'s Pro grant, so free wins.
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-free", "--onboarding", "--onboarding-reveal"]
        app.launch()
        let revealCTA = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(revealCTA.waitForExistence(timeout: 30), "Didn't land on the plan reveal.")
        revealCTA.tap()
    }

    /// Reveal goes straight to the personalized checkout, with no generic welcome in between.
    private func advanceToCheckout(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["YOUR GOAL"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Welcome to momentum."].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Built into every week'")
        ).firstMatch.exists)
    }

    /// HARD: neither page carries an X, the app behind checkout cannot be reached, and force-quitting
    /// simply re-raises checkout from the persisted gate. This is the conversion contract for new
    /// onboarding users; contextual paywalls are covered separately and remain dismissible.
    func testHardPaywallHasNoCloseAndSurvivesRelaunch() {
        let app = XCUIApplication()
        launchToPaywall(app)

        // Checkout: seven-day annual trial, Restore, and no bypass.
        advanceToCheckout(app)
        let trial = app.buttons["Start my 7-day free trial"]
        XCTAssertTrue(trial.waitForExistence(timeout: 10), "The annual trial CTA is missing.")
        XCTAssertFalse(app.buttons["Close"].exists, "The hard-wall checkout must not carry a close button.")
        XCTAssertTrue(app.buttons["Restore"].exists, "Checkout must keep Restore reachable.")
        app.swipeDown()
        XCTAssertTrue(trial.waitForExistence(timeout: 3),
                      "A downward dismissal gesture escaped the hard-wall checkout.")

        XCTAssertFalse(app.buttons["Back"].exists, "Direct checkout must not restart the feature tour.")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)

        // Force-quit AT checkout, then relaunch without the onboarding deep link.
        app.terminate()
        app.launchArguments = ["--seed-demo", "--debug-free"]
        app.launch()
        XCTAssertTrue(app.buttons["Start my 7-day free trial"].waitForExistence(timeout: 20),
                      "The hard gate did not survive a force-quit.")
        XCTAssertFalse(app.buttons["Close"].exists, "The relaunch gate must remain hard.")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The app is reachable behind the hard wall.")
    }

    /// Force-quitting the wall and subscribing from the RELAUNCH gate must still offer the account.
    ///
    /// The relaunch gate is hosted by `RootView`, not by `OnboardingFlow`, so it never ran
    /// onboarding's paywall → `.account` hand-off. Before the fix this dropped the athlete straight
    /// into the app: a PAYING permanent guest, anonymous to RevenueCat, with no cloud copy of what
    /// they'd just bought. Driven as a guest with a seeded profile, because the gate is deliberately
    /// suppressed until a profile exists (`!profiles.isEmpty`).
    func testRelaunchGatePurchaseStillOffersTheAccount() {
        let app = XCUIApplication()
        let args = ["--seed-demo", "--onboarding-guest", "--debug-free"]
        app.launchArguments = ["--reset-store"] + args + ["--onboarding", "--onboarding-reveal"]
        app.launch()
        let revealCTA = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(revealCTA.waitForExistence(timeout: 30), "Didn't land on the plan reveal.")
        revealCTA.tap()

        advanceToCheckout(app)

        // Force-quit AT the wall, then come back with no onboarding deep link at all.
        app.terminate()
        app.launchArguments = args
        app.launch()

        // The wall is re-raised from the persisted gate flag — force-quitting is not a way in.
        // The relaunch gate re-enters the flow AT the checkout page (the story was told last
        // launch), so the trial CTA is the first thing on screen.
        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Unlock my plan' OR label BEGINSWITH 'Continue ·' OR label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 20), "The gate didn't survive a force-quit.")
        XCTAssertFalse(app.buttons["Close"].exists, "The relaunch gate must not expose a close button.")
        // Hittable, not exists: this gate covers the real tab shell (unlike onboarding's, which sits
        // over a blank canvas), so the tab bar is legitimately still in the hierarchy behind it.
        // What matters is that nothing back there can be reached.
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The app was reachable behind the wall.")
        cta.tap()

        // …and buying HERE still hands off to the account beat rather than dropping into the app.
        if !app.staticTexts["Save your progress"].waitForExistence(timeout: 20) {
            XCTFail("""
                Subscribing from the relaunch gate skipped the account beat — paying guest. \
                on screen: tabBar=\(app.tabBars.firstMatch.exists) \
                stillOnWall=\(cta.exists) \
                welcome=\(app.buttons["Build my plan"].exists) \
                onboarding=\(app.buttons["Continue"].exists)
                """)
        }
    }

    /// A hard gate the store can't serve must not brick the app.
    ///
    /// Offline — or during a StoreKit/RevenueCat outage, or against a mis-configured offering — there
    /// is no package to buy and no receipt to restore, so before this the athlete sat on a wall with
    /// no close, no swipe, and nothing that could ever succeed. Force-quitting only re-raised it.
    /// That is also what an App Review device on a flaky network sees, which is a 2.1 rejection.
    /// `--paywall-pricing-down` is the seam for that state (it's otherwise unreachable on a sim).
    func testStoreUnreachableHardGateOffersADeferral() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-free", "--paywall-pricing-down",
                               "--onboarding", "--onboarding-reveal"]
        app.launch()
        let revealCTA = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(revealCTA.waitForExistence(timeout: 30), "Didn't land on the plan reveal.")
        revealCTA.tap()

        // The personalized checkout still opens when store pricing is unavailable.
        advanceToCheckout(app)

        // Pricing never loaded, so the CTA is a Retry rather than a price we can't stand behind.
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Expected the pricing-unavailable paywall.")
        let escape = app.buttons.matching(NSPredicate(format: "label CONTAINS 'ask again'")).firstMatch
        XCTAssertFalse(escape.exists, "The escape must not exist before the store has actually failed.")

        // Two genuine failures — the alert's "Not now" dismisses without counting as a purchase.
        for attempt in 1...2 {
            retry.tap()
            let dismissAlert = app.alerts.buttons["Not now"]
            XCTAssertTrue(dismissAlert.waitForExistence(timeout: 10),
                          "Attempt \(attempt) should surface a failure alert.")
            dismissAlert.tap()
        }

        XCTAssertTrue(escape.waitForExistence(timeout: 5),
                      "Two store failures on a hard gate must offer a way past it.")
        escape.tap()

        // It's a deferral, not a bypass: they get in, and the wall is back on the next launch.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20),
                      "Deferring should let the athlete into the app for this launch.")
        app.terminate()
        app.launchArguments = ["--seed-demo", "--debug-free", "--paywall-pricing-down"]
        app.launch()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 20),
                      "The wall must return on the next launch — the deferral is not persisted.")
    }

    /// The trial CTA still grants entitlement and advances — the paid path is the only path through.
    /// Lands in the app rather than on the account beat because `--seed-demo` is already signed in as
    /// `demo-user`, and `goToAccountBeat` deliberately never asks a signed-in athlete to sign in
    /// again. The guest route to the account beat is covered by `GuestEntryUITests`.
    func testTrialUnlocksAndAdvances() {
        let app = XCUIApplication()
        launchToPaywall(app)
        advanceToCheckout(app)

        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Unlock my plan' OR label BEGINSWITH 'Continue ·' OR label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 10), "The flow didn't reach the checkout page.")
        cta.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20),
                      "Subscribing didn't carry the athlete through the wall into the app.")
    }
}
