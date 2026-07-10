import XCTest

/// Live audit of the auth flows beyond first sign-up (EmailAuthUITests owns that one):
/// error messaging, password reset → sign out → sign back in, and guest → email upgrade.
///
/// ⚠️ NETWORK + ORCHESTRATED: run these tests INDIVIDUALLY, in order, against the live project,
/// with the app already installed (the local store's profile keeps the walks short). Credentials
/// come in via TEST_RUNNER_ env vars (E2E_EMAIL / E2E_PASS / E2E_NEWPASS); between tests the
/// orchestrator confirms the user (admin API) and fires the recovery link (see the session notes
/// in scripts/e2e_email_confirm.sh for the pattern). Clean up e2e.* users afterwards.
final class AuthFlowsUITests: XCTestCase {

    private var email: String { ProcessInfo.processInfo.environment["E2E_EMAIL"] ?? "" }
    private var pass: String { ProcessInfo.processInfo.environment["E2E_PASS"] ?? "" }
    private var newPass: String { ProcessInfo.processInfo.environment["E2E_NEWPASS"] ?? "" }

    private func launchAtGate() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--reset-auth", "--uitest-password"]
        app.launch()
        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10), "reset-auth should land on the gate")
        getStarted.tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 5))
        return app
    }

    private func signIn(_ app: XCUIApplication, email: String, password: String) {
        signInFields(app, email: email, password: password)
        app.buttons["Sign in"].tap()
    }

    // 1 — inline error truthfulness against a pre-created UNCONFIRMED user (admin-created by
    // the orchestrator — signing up in-app would burn the built-in mailer's tiny hourly email
    // budget; the signup-prompt beat itself is covered live by EmailAuthUITests).
    func test1_messagingWrongPasswordAndUnconfirmed() throws {
        continueAfterFailure = false
        XCTAssertFalse(email.isEmpty, "pass TEST_RUNNER_E2E_EMAIL")
        let app = launchAtGate()

        // Sign-in with the right password while unconfirmed → the specific nudge.
        signIn(app, email: email, password: pass)
        XCTAssertTrue(app.staticTexts["Confirm your email first — check your inbox for the link we sent."]
            .waitForExistence(timeout: 20), "unconfirmed sign-in should say so, not 'wrong password'")
        attach(app, "error-unconfirmed")

        // Wrong password → honest inline error (server checks the password before confirmation).
        let passwordField = app.textFields["Password"]
        clearField(passwordField, in: app)
        passwordField.typeText("definitely-wrong-1")
        app.buttons["Sign in"].tap()
        XCTAssertTrue(app.staticTexts["That email and password don't match an account."]
            .waitForExistence(timeout: 20), "wrong-password message should show")
        attach(app, "error-wrong-password")
    }

    // 2 — recovery link → set new password → sign out (Settings) → sign in with the new password.
    // Orchestrator: confirm the user first, then fire the recovery deep link ~20s into the run.
    func test2_passwordResetSignOutSignIn() throws {
        XCTAssertFalse(newPass.isEmpty, "pass TEST_RUNNER_E2E_NEWPASS")
        let app = launchAtGate()

        // The recovery link signs the athlete in AND raises the set-new-password sheet.
        let newField = app.textFields["New password"]
        XCTAssertTrue(newField.waitForExistence(timeout: 90),
                      "recovery deep link should raise the New password sheet (orchestrator running?)")
        attach(app, "recovery-sheet")
        newField.tap()
        newField.typeText(newPass)
        let confirmField = app.textFields["Confirm password"]
        confirmField.tap()
        confirmField.typeText(newPass)
        app.buttons["Save password"].tap()

        // Sheet falls; the recovery session is live → the app proper (profile exists → tabs).
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 30),
                      "after saving the password the athlete should be in the app")
        attach(app, "recovery-signed-in")

        // Sign out from Settings.
        app.tabBars.buttons["Profile"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let signOut = app.buttons["Sign out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        scrollTo(signOut, in: app)   // the account card sits low on the page
        signOut.tap()
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 10), "sign-out should return to the gate")

        // Sign back in with the NEW password.
        app.buttons["Get started"].tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 5))
        signIn(app, email: email, password: newPass)
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 30),
                      "the new password should sign in")
        attach(app, "signed-in-new-password")
    }

    // 3 — guest → Settings → "More ways to sign in" → email sign-in upgrades the account
    // (onFirstCloudSession claims the local identity; verified in Postgres by the orchestrator).
    func test3_guestUpgradeViaEmail() throws {
        let app = launchAtGate()

        app.buttons["Continue without an account"].tap()
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 15), "guest should enter the app")

        app.tabBars.buttons["Profile"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let more = app.buttons["More ways to sign in — Google or email"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "guest card should offer more sign-in options")
        scrollTo(more, in: app)
        attach(app, "guest-card")
        more.tap()

        // The gate's sign-in page as a cover (X to close, no guest row).
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close"].exists, "cover shows a close, not a back chevron")
        XCTAssertFalse(app.buttons["Continue without an account"].exists, "no guest row inside the cover")
        signIn(app, email: email, password: newPass)

        // Success dismisses the cover; the account card flips from Guest to the email identity.
        XCTAssertTrue(app.staticTexts["Email account"].waitForExistence(timeout: 30),
                      "the account card should show the email identity after upgrade")
        attach(app, "upgraded-account-card")
        sleep(6)   // let the fire-and-forget claim land server-side before the orchestrator checks
    }

    // 4 — in-app account deletion (App Store 5.1.1(v)): sign in, delete from Settings,
    // land back on the gate. The orchestrator verifies the server side is empty afterwards.
    func test4_deleteAccount() throws {
        let app = launchAtGate()
        signIn(app, email: email, password: pass)
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 30), "sign-in should enter the app")

        app.tabBars.buttons["Profile"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let deleteRow = app.buttons["Delete account"]
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 10))
        scrollTo(deleteRow, in: app)
        attach(app, "delete-account-row")
        deleteRow.tap()

        // The confirmation dialog spells out exactly what goes and what stays.
        let confirm = app.buttons["Delete my account"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation dialog should appear")
        attach(app, "delete-account-dialog")
        confirm.tap()

        // Server delete + local sign-out → back at the gate.
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 30),
                      "account deletion should land back on the gate")
        attach(app, "post-delete-gate")
    }

    // MARK: helpers

    /// Fill the email/password boxes without submitting, clearing any prior values.
    private func signInFields(_ app: XCUIApplication, email: String, password: String) {
        let emailField = app.textFields["Email"]
        clearField(emailField, in: app)
        emailField.typeText(email)
        let passwordField = app.textFields["Password"]
        clearField(passwordField, in: app)
        passwordField.typeText(password)
    }

    /// Reliable clear: caret to the right edge, then delete through the whole value
    /// (triple-tap select is flaky on the sim).
    private func clearField(_ field: XCUIElement, in app: XCUIApplication) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 3))
    }

    /// XCUITest doesn't auto-scroll to offscreen elements — nudge until hittable.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
