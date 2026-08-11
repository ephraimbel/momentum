import XCTest

/// Live end-to-end proof of the email+password gate (PRD §8.11): create a real Supabase account
/// from the sign-in page, confirm it via the emailed deep link, land in onboarding, walk it to
/// the plan reveal — which fires the @handle claim against the live backend (psql-verified).
///
/// ⚠️ NETWORK + COMPANION SCRIPT: this test signs up a real user on the live project, then
/// WAITS at the "check your email" beat for the confirmation deep link. Run
/// `scripts/e2e_email_confirm.sh <sim-udid>` in parallel — it generates the link via the admin
/// API and opens it on the sim, which signs the athlete in and resumes the walk. Run the test
/// deliberately (`-only-testing:MomentumUITests/EmailAuthUITests`) against a FRESH install
/// (uninstall first — a stored session skips the gate), and clean up `e2e.*` users afterwards.
final class EmailAuthUITests: XCTestCase {

    func testEmailSignUpThroughOnboardingToReveal() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // --uitest-password: opt the SecureField out of AutoFill — iOS's "Use Strong Password?"
        // takeover sheet otherwise swallows typeText (proven by the first run's recording).
        app.launchArguments = ["--uitest-password"]
        app.launch()   // otherwise unmodified: the real gate, the real network

        // Beat 1 → Beat 2. The welcome's primary CTA goes into setup with no account
        // (2026-07-27); the account page is reached through the returning-athlete door.
        let returning = app.buttons["I already have an account"]
        XCTAssertTrue(returning.waitForExistence(timeout: 10), "welcome beat should show on a fresh install")
        returning.tap()

        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5), "email box should be on the account page")
        attach(app, "signin-page")

        // Flip to create-account mode
        app.buttons["New here? Create an account"].tap()
        XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 3))
        attach(app, "signin-create-mode")

        // A unique throwaway address per run (the confirmation link is fetched via the admin
        // API by the companion script — deliverability doesn't matter).
        let stamp = Int(Date().timeIntervalSince1970) % 100_000_000
        let email = "e2e.momentum.\(stamp)@gmail.com"
        emailField.tap()
        emailField.typeText(email)
        // Plain TextField under --uitest-password (no secure entry → no AutoFill interference).
        let passwordField = app.textFields["Password"]
        passwordField.tap()
        passwordField.typeText("m0mentum-e2e-pass")
        XCTAssertFalse((passwordField.value as? String ?? "").isEmpty, "password should have been typed")

        let create = app.buttons["Create account"]
        XCTAssertTrue(create.isEnabled, "both boxes filled — submit should be enabled")
        create.tap()

        // Confirmations are ON: the account exists but there's no session yet — the gate shows
        // the "check your email" beat. This asserts the confirm-gated UX in its own right.
        let confirmPrompt = app.staticTexts["Almost there — tap the link we just emailed you and you're in."]
        XCTAssertTrue(confirmPrompt.waitForExistence(timeout: 30), "signup should show the confirm-email prompt")
        attach(app, "signin-confirm-prompt")

        // Now wait for the companion script to open the confirmation deep link on this sim —
        // momentum://auth-callback signs the athlete in, the gate falls, onboarding presents.
        // Opening a custom-scheme URL raises iOS's system "Open in 'momentum'?" confirmation
        // (exactly what a real user taps after clicking the email link) — tap Open when it shows.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let nameTitle = app.staticTexts["What should we call you?"]
        var landed = false
        for _ in 0..<40 {   // ~120s
            let openBtn = springboard.buttons["Open"]
            if openBtn.exists && openBtn.isHittable { openBtn.tap() }
            if nameTitle.waitForExistence(timeout: 3) { landed = true; break }
        }
        XCTAssertTrue(landed,
                      "confirmation link should sign in and land in onboarding (is scripts/e2e_email_confirm.sh running?)")

        // iOS's "Save Password?" panel floats over onboarding after signup, sometimes proxied
        // via springboard, sometimes not (runs 3/8/9/10 each lost a different race against it).
        // Decline it via whichever proxy sees it, best-effort — then avoid the keyboard entirely:
        // the name step advances empty (display name is editable later in Edit Profile) and the
        // identity step's @handle is auto-prefilled by the suggester, so the rest of the walk is
        // taps only.
        for _ in 0..<10 {
            for notNow in [springboard.buttons["Not Now"], app.buttons["Not Now"]] where notNow.exists && notNow.isHittable {
                notNow.tap()
                sleep(1)
            }
            let cont = app.buttons["Continue"]
            if cont.exists && cont.isHittable && cont.isEnabled { break }
            sleep(1)
        }

        // Name step — empty name is allowed (@handle is the required identity). Tap-and-verify:
        // a single tap can land mid-entrance-animation and miss (run 11).
        let identityTitle = app.staticTexts["Claim your @handle"]
        for _ in 0..<6 where !identityTitle.exists {
            let cont = app.buttons["Continue"]
            if cont.exists && cont.isHittable && cont.isEnabled { cont.tap() }
            _ = identityTitle.waitForExistence(timeout: 2)
        }

        // Identity step — the suggester should prefill a free handle from the email local-part.
        XCTAssertTrue(identityTitle.waitForExistence(timeout: 10))
        let handleField = app.textFields.firstMatch
        let prefilled = NSPredicate(format: "value != '' AND value != nil")
        expectation(for: prefilled, evaluatedWith: handleField)
        waitForExpectations(timeout: 15)
        let handle = (handleField.value as? String) ?? ""
        XCTAssertFalse(handle.isEmpty, "handle suggestion should prefill")
        attach(app, "onboarding-identity-\(handle)")
        tapContinue(app)

        // Walk the remaining steps generically: answer the two steps that demand input,
        // dismiss opt-in beats, Continue through the rest.
        let week1 = app.staticTexts["Week 1"]   // the plan reveal
        // The health step's Continue raises the real HealthKit sheet (5.1.1(iv): no skip button
        // anymore) — it presents from com.apple.Health, so drive that process directly.
        let health = XCUIApplication(bundleIdentifier: "com.apple.Health")
        for _ in 0..<25 {
            if week1.exists { break }
            grantHealthSheet(health)
            if app.staticTexts["What do you want to do?"].exists,
               !app.buttons["Continue"].isEnabled {
                app.staticTexts["Lift weights"].firstMatch.tap()
            }
            let maybeLater = app.buttons["Maybe later"]
            let cont = app.buttons["Continue"]
            if cont.exists && cont.isHittable && cont.isEnabled {
                cont.tap()
            } else if maybeLater.exists && maybeLater.isHittable {
                maybeLater.tap()
            } else {
                sleep(2)   // the "building" beat, or a step still animating in
            }
        }
        XCTAssertTrue(week1.waitForExistence(timeout: 60), "should reach the plan reveal")
        attach(app, "plan-reveal")
        // buildPlan() fired the handle claim fire-and-forget — give it a beat to land server-side.
        sleep(6)
        print("E2E-EMAIL: \(email) HANDLE: \(handle)")
    }

    private func tapContinue(_ app: XCUIApplication) {
        let cont = app.buttons["Continue"]
        XCTAssertTrue(cont.waitForExistence(timeout: 5))
        XCTAssertTrue(cont.isEnabled)
        cont.tap()
    }

    /// Grant the HealthKit authorization sheet if it's up (same pattern as HealthImportUITests).
    private func grantHealthSheet(_ health: XCUIApplication) {
        for label in ["Turn On All", "Turn On All Categories", "Enable All"] {
            let sw = health.switches[label]
            if sw.exists && sw.isHittable { sw.tap() }
            let btn = health.buttons[label]
            if btn.exists && btn.isHittable { btn.tap() }
        }
        let allow = health.buttons["Allow"]
        if allow.exists && allow.isHittable { allow.tap() }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
