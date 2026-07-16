import XCTest

/// Guest door (App Review path): `--reset-auth` lands on the gate, "Get started" reveals all
/// three doors (Apple / Google / guest), and "Continue without an account" enters the app —
/// no network, no credentials. The full guest → email upgrade (server-side claim) lives in
/// `AuthFlowsUITests.test3_guestUpgradeViaEmail` (orchestrated, live project).
final class GuestEntryUITests: XCTestCase {

    func testGuestDoorEntersTheApp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--reset-auth"]
        app.launch()

        // Page 1 — the welcome hero.
        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10), "reset-auth should land on the gate")
        attach("1-gate")
        getStarted.tap()

        // Page 2 — every door present: Apple (4.8 requires it beside Google), Google, guest.
        let guest = app.buttons["Continue without an account"]
        XCTAssertTrue(guest.waitForExistence(timeout: 5), "the guest door must exist on the sign-in page")
        XCTAssertTrue(app.buttons["Sign in with Apple"].exists, "SIWA must accompany third-party login (4.8)")
        XCTAssertTrue(app.buttons["Continue with Google"].exists)
        attach("2-doors")
        guest.tap()

        // Entered: the gate falls; a fresh container shows onboarding, a lived-in one shows tabs.
        let tabs = app.tabBars.firstMatch
        let entered = tabs.waitForExistence(timeout: 15)
        if !entered {
            XCTAssertFalse(getStarted.exists, "guest tap must leave the gate (onboarding or tabs)")
        }
        attach("3-entered")

        // Relaunch WITHOUT reset — the guest session must persist (no re-gate).
        app.terminate()
        app.launchArguments = []
        app.launch()
        let regated = app.buttons["Get started"].waitForExistence(timeout: 6)
        XCTAssertFalse(regated, "a guest must stay signed in across relaunch")
        attach("4-relaunch-still-in")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
