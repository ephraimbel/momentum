import XCTest

/// The onboarding paywall (SOFT since 2026-08-06, reversing the 2026-07-28 hard flip): the last
/// beat of setup offers the trial, a subscription, Restore — and an X that skips it for good.
/// Verifies both halves of that contract: closing moves on (and stays closed across launches),
/// and the trial still grants-and-advances. Uses the local purchase seam (no RevenueCat in
/// DEBUG), so the trial tap genuinely exercises the grant → dismiss → advance path.
final class OnboardingPaywallUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// Enters at the LOCATION PRIMER, the step immediately before the paywall since the rating beat
    /// was removed (2026-08-22): reveal → notifications → primers → paywall → account. Driving from
    /// `--onboarding-reveal` used to work and silently stopped when those beats moved between the
    /// reveal and the wall; entering one step out keeps this suite pinned to the real hand-off.
    private func launchToPaywall(_ app: XCUIApplication) {
        // Seeded profile (the flow needs one) + forced-free entitlement so the paywall actually
        // shows — `--debug-free` is read before `--seed-demo`'s Pro grant, so free wins.
        app.launchArguments = ["--seed-demo", "--debug-free", "--onboarding", "--onboarding-primers"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // The location primer is now the last beat before the wall (the rating beat that used to sit
        // between them was removed 2026-08-22), so its Continue IS the hand-off under test.
        // 30s, not 15: a cold launch that also has to run `--seed-demo` can blow well past 15s on a
        // loaded machine, which showed up once as a phantom failure of this suite under CPU load.
        XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 30),
                      "Didn't land on the location primer.")
        let cont = app.buttons["Continue"]
        XCTAssertTrue(cont.waitForExistence(timeout: 10), "The primer must offer Continue.")
        cont.tap()
    }

    // The tour's CTA is a STORE fact: "Try now" only while an intro trial exists, "Continue"
    // otherwise (8a22e8e, trial retired 2026-08-20). The walkers match either so they pin the
    // hand-off, not the offer. (The primer's own Continue sits under the cover by then.)

    /// Walks the two-page flow (2026-08-05) from its device-tour opener to the checkout page.
    /// No system prompts on the way — the tour never asks for permissions; onboarding already did.
    private func advanceToCheckout(_ app: XCUIApplication) {
        let tryNow = app.buttons.matching(NSPredicate(format: "label == 'Try now' OR label == 'Continue'")).firstMatch
        XCTAssertTrue(tryNow.waitForExistence(timeout: 10), "Didn't land on the paywall's tour page.")
        tryNow.tap()
    }

    /// SOFT: the X lives on the checkout page (and ONLY there — the tour keeps its own CTA as
    /// the way forward), closing lands in the app un-entitled, and the skip is a decision — the
    /// wall must NOT re-raise on the next launch (the X clears the persisted gate flag; a wall
    /// that comes back after being closed is a hard gate with extra steps).
    func testSoftPaywallCloseSkipsToTheAppForGood() {
        let app = XCUIApplication()
        launchToPaywall(app)

        // The tour page: no X here (user call 2026-08-06) — Restore is the only chrome.
        let tryNow = app.buttons.matching(NSPredicate(format: "label == 'Try now' OR label == 'Continue'")).firstMatch
        XCTAssertTrue(tryNow.waitForExistence(timeout: 10), "Paywall didn't follow the location primer.")
        XCTAssertFalse(app.buttons["Close"].exists,
                       "The tour page must NOT carry the close button — the X is checkout-only.")
        XCTAssertTrue(app.buttons["Restore"].exists, "The paywall must still offer Restore.")

        // Through to the checkout page: the X survives to where the money is.
        advanceToCheckout(app)
        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue ·' OR label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 10), "The flow didn't reach the checkout page.")
        let close = app.buttons["Close"]
        XCTAssertTrue(close.exists, "The checkout page must offer the close button too.")

        // Close it. `--seed-demo` is already signed in as demo-user, so `goToAccountBeat`
        // correctly skips the account ask and the skipper lands in the app on the free tier.
        close.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20),
                      "Closing the soft paywall didn't land in the app.")

        // …and it stays closed: relaunch with no onboarding deep link — no wall.
        app.terminate()
        app.launchArguments = ["--seed-demo", "--debug-free"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20),
                      "The app didn't come back up after the relaunch.")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == 'Try now' OR label == 'Continue'")).firstMatch.exists || app.buttons["Retry"].exists,
                       "The wall re-raised after being closed — the X must clear the gate flag.")
    }

    /// A GUEST who closes the wall must still be offered the account beat — the X takes the same
    /// hand-off as a purchase (`onDismiss: goToAccountBeat()`), and skipping that too enters the
    /// app. This is the path `testSoftPaywallCloseSkipsToTheAppForGood` can't see: `--seed-demo`
    /// is signed in, so its close lands straight in the app.
    func testCloseHandsOffToTheAccountBeatForGuests() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--onboarding-guest", "--debug-free",
                               "--onboarding", "--onboarding-primers"]
        // The location primer asks for location ~0.55s after it settles; dismiss it however it lands.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // The last beat before the wall since the rating beat was removed (2026-08-22).
        XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 30),
                      "Didn't land on the location primer.")
        let primerContinue = app.buttons["Continue"]
        XCTAssertTrue(primerContinue.waitForExistence(timeout: 10), "The primer must offer Continue.")
        primerContinue.tap()

        advanceToCheckout(app)
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The checkout page must offer the X.")
        close.tap()

        // The skipper is offered the account, exactly like the subscriber.
        XCTAssertTrue(app.staticTexts["Save your progress"].waitForExistence(timeout: 10),
                      "Closing the wall as a guest must hand off to the account beat.")
        app.buttons["Not now"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15),
                      "Declining the account after a skip still enters the app.")
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
        app.launchArguments = args + ["--onboarding", "--onboarding-primers"]
        // The location primer asks for location ~0.55s after it settles; dismiss it however it lands.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // The last beat before the wall since the rating beat was removed (2026-08-22).
        XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 30),
                      "Didn't land on the location primer.")
        let primerContinue = app.buttons["Continue"]
        XCTAssertTrue(primerContinue.waitForExistence(timeout: 10), "The primer must offer Continue.")
        primerContinue.tap()

        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Try now' OR label == 'Continue'")).firstMatch.waitForExistence(timeout: 10),
                      "Paywall didn't follow the location primer.")

        // Force-quit AT the wall, then come back with no onboarding deep link at all.
        app.terminate()
        app.launchArguments = args
        app.launch()

        // The wall is re-raised from the persisted gate flag — force-quitting is not a way in.
        // The relaunch gate re-enters the flow AT the checkout page (the story was told last
        // launch), so the trial CTA is the first thing on screen.
        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue ·' OR label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 20), "The gate didn't survive a force-quit.")
        XCTAssertTrue(app.buttons["Close"].exists, "The relaunch gate is soft too — the X must be there.")
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
                               "--onboarding", "--onboarding-primers"]
        // The location primer asks for location ~0.55s after it settles; dismiss it however it lands.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // The last beat before the wall since the rating beat was removed (2026-08-22).
        XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 30),
                      "Didn't land on the location primer.")
        let primerContinue = app.buttons["Continue"]
        XCTAssertTrue(primerContinue.waitForExistence(timeout: 10), "The primer must offer Continue.")
        primerContinue.tap()

        // The first two pages sell without transacting, so they advance even with the store down.
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

        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue ·' OR label BEGINSWITH 'Start my'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 10), "The flow didn't reach the checkout page.")
        cta.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20),
                      "Subscribing didn't carry the athlete through the wall into the app.")
    }
}
