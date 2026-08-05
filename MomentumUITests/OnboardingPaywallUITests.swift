import XCTest

/// The onboarding paywall (HARD, 2026-07-28): the last beat of setup is a wall with no way past it
/// but the trial, a subscription, or Restore. Verifies both halves of that contract — no escape
/// hatch is rendered, and the trial still grants-and-advances to the account beat.
/// Uses the local purchase seam (no RevenueCat in DEBUG), so the trial tap genuinely exercises the
/// grant → dismiss → advance path.
final class OnboardingPaywallUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// Enters at the RATING beat, which is the step immediately before the paywall since the
    /// 2026-07-26 reorder (reveal → notifications → rating → paywall → account). Driving from
    /// `--onboarding-reveal` used to work and silently stopped when those beats moved between the
    /// reveal and the wall; entering one step out keeps this suite pinned to the real hand-off.
    private func launchToPaywall(_ app: XCUIApplication) {
        // Seeded profile (the flow needs one) + forced-free entitlement so the paywall actually
        // shows — `--debug-free` is read before `--seed-demo`'s Pro grant, so free wins.
        app.launchArguments = ["--seed-demo", "--debug-free", "--onboarding", "--onboarding-rate"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // 30s, not 15: a cold launch that also has to run `--seed-demo` can blow well past 15s on a
        // loaded machine, which showed up once as a phantom failure of this suite under CPU load.
        let notNow = app.buttons["Not now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 30), "Didn't land on the rating beat.")
        notNow.tap()
    }

    /// Walks the two-page flow (2026-08-05) from its device-tour opener to the checkout page.
    /// No system prompts on the way — the tour never asks for permissions; onboarding already did.
    private func advanceToCheckout(_ app: XCUIApplication) {
        let tryNow = app.buttons["Try now"]
        XCTAssertTrue(tryNow.waitForExistence(timeout: 10), "Didn't land on the paywall's tour page.")
        tryNow.tap()
    }

    /// HARD: no close affordance, no swipe-away, and nothing behind the wall is reachable. Pinning
    /// the *absence* of the button is the whole point — `hard` is a default-valued parameter, so a
    /// call site that silently reverts to `hard: false` would still compile and still pass every
    /// other paywall test in the suite.
    func testHardPaywallOffersNoEscape() {
        let app = XCUIApplication()
        launchToPaywall(app)

        // The tour page: still a wall — no close, Restore reachable, swipe-proof.
        let tryNow = app.buttons["Try now"]
        XCTAssertTrue(tryNow.waitForExistence(timeout: 10), "Paywall didn't follow the rating beat.")
        XCTAssertFalse(app.buttons["Close"].exists,
                       "The onboarding paywall must NOT offer a close button (hard gate).")
        // Restore stays reachable — a hard wall with no way to reclaim a purchase you already made
        // is both hostile and an App Review rejection (3.1.1).
        XCTAssertTrue(app.buttons["Restore"].exists, "A hard paywall must still offer Restore.")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(tryNow.exists, "Swiping down dismissed the hard paywall's tour page.")

        // Through to the checkout page: the same contract holds where the money is.
        advanceToCheckout(app)
        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 10), "The flow didn't reach the checkout page.")
        XCTAssertFalse(app.buttons["Close"].exists,
                       "The checkout page must NOT offer a close button (hard gate).")
        XCTAssertTrue(app.buttons["Restore"].exists, "Restore must survive to the checkout page.")

        // Swipe-down is the other escape: the cover disables interactive dismissal in hard mode.
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(cta.exists, "Swiping down dismissed the hard paywall.")
        XCTAssertFalse(app.staticTexts["Save your progress"].exists,
                       "The wall handed off to the account beat without an entitlement.")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The wall let an un-entitled athlete into the app.")
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
        app.launchArguments = args + ["--onboarding", "--onboarding-rate"]
        app.launch()
        app.tap()

        let notNow = app.buttons["Not now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 30), "Didn't land on the rating beat.")
        notNow.tap()

        XCTAssertTrue(app.buttons["Try now"].waitForExistence(timeout: 10),
                      "Paywall didn't follow the rating beat.")

        // Force-quit AT the wall, then come back with no onboarding deep link at all.
        app.terminate()
        app.launchArguments = args
        app.launch()

        // The wall is re-raised from the persisted gate flag — force-quitting is not a way in.
        // The relaunch gate re-enters the flow AT the checkout page (the story was told last
        // launch), so the trial CTA is the first thing on screen.
        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 20), "The hard gate didn't survive a force-quit.")
        XCTAssertFalse(app.buttons["Close"].exists, "The relaunch gate must be hard too — no close.")
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
                welcome=\(app.buttons["Get started"].exists) \
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
        app.launchArguments = ["--seed-demo", "--debug-free", "--paywall-pricing-down",
                               "--onboarding", "--onboarding-rate"]
        app.launch()
        app.tap()

        let notNow = app.buttons["Not now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 30), "Didn't land on the rating beat.")
        notNow.tap()

        // The first two pages sell without transacting, so they advance even with the store down.
        advanceToCheckout(app)

        // Pricing never loaded, so the CTA is a Retry rather than a price we can't stand behind.
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Expected the pricing-unavailable paywall.")
        let escape = app.buttons.matching(NSPredicate(format: "label CONTAINS 'ask again'")).firstMatch
        XCTAssertFalse(escape.exists, "The escape must not exist before the store has actually failed.")
        XCTAssertFalse(app.buttons["Close"].exists, "Still a hard gate until the store proves unreachable.")

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

        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 10), "The flow didn't reach the checkout page.")
        cta.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20),
                      "Subscribing didn't carry the athlete through the wall into the app.")
    }
}
