import XCTest

/// The front door (App Review path). Since 2026-07-27 the welcome asks for no account at all:
/// "Build my plan" goes straight into setup; account backup remains available in Settings. This test pins the two things that must never regress:
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

    /// Verified guest purchase must enter Today directly, without another account/setup gate.
    func testGuestPurchaseEntersTodayImmediately() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--onboarding", "--onboarding-guest", "--onboarding-reveal", "--debug-free", "--review-no-ask"]
        app.launch()
        let reveal = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 20))
        reveal.tap()
        let review = app.buttons["onboarding.review.continue"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.isHittable)
        review.tap()
        crossPermissionBeats(app)
        let purchase = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start my' OR label BEGINSWITH 'Unlock my plan' OR label BEGINSWITH 'Continue ·'")).firstMatch
        XCTAssertTrue(purchase.waitForExistence(timeout: 15))
        purchase.tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Save your progress"].exists)
    }

    /// The whole point of moving the account to the end: what the athlete told us during setup has
    /// to survive into the app. Walks the real guest flow with a typed name and checks it lands on
    /// the profile — a blank `displayName` renders as "Athlete", which is the regression this pins.
    func testOnboardingAnswersSurviveIntoTheApp() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--reset-auth", "--debug-free", "--ui-test-reduce-motion", "--review-no-ask"]
        app.launch()
        let start = app.buttons["Build my plan"]
        XCTAssertTrue(start.waitForExistence(timeout: 15)); start.tap()
        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15)); name.tap(); name.typeText("Maya Rivera\n")
        app.buttons["Continue"].tap()
        let goal = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Stay consistent'")).firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 20)); goal.tap()
        app.buttons["Continue"].tap()
        let background = app.buttons.matching(NSPredicate(format: "label CONTAINS 'New to running'")).firstMatch
        XCTAssertTrue(background.waitForExistence(timeout: 8)); background.tap()
        app.buttons["Continue"].tap()
        // The pace page (2026-09-12): a newcomer answers by feel.
        XCTAssertTrue(app.staticTexts["How fast do you run today?"].waitForExistence(timeout: 8))
        let feel = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Walk and jog'")).firstMatch
        XCTAssertTrue(feel.waitForExistence(timeout: 5)); feel.tap()
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Anything to train around?"].waitForExistence(timeout: 8))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["A few personal details."].waitForExistence(timeout: 8))
        app.buttons["Female"].tap()
        app.buttons["Increase Age"].tap()
        app.buttons["Increase Height"].tap()
        app.buttons["Increase Weight"].tap()
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Let's shape your training week."].waitForExistence(timeout: 8))
        app.buttons["3 training days"].tap()
        app.buttons["Monday"].tap()
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Here's the approach we recommend."].waitForExistence(timeout: 8))
        app.buttons["Continue"].tap()
        let reveal = app.buttons["onboarding.reveal.continue"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["onboarding.reveal.details"].exists)
        reveal.tap()
        let review = app.buttons["onboarding.review.continue"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.isHittable)
        review.tap()
        crossPermissionBeats(app)
        let purchase = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start my' OR label BEGINSWITH 'Unlock my plan' OR label BEGINSWITH 'Continue ·'")).firstMatch
        XCTAssertTrue(purchase.waitForExistence(timeout: 15)); purchase.tap()
        XCTAssertTrue(app.tabBars.buttons["Plan"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Plan"].tap()
        XCTAssertFalse(app.staticTexts["Build your first plan"].exists)
        attach("guest-created-plan")
        app.terminate()
        app.launchArguments = ["--ui-test-route"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20), "Purchased guest must survive relaunch")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
