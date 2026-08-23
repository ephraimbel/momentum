import XCTest

/// The sign-in / create-account form itself — the parts that are logic, not looks.
///
/// `AuthFlowsUITests` and `EmailAuthUITests` cover the round trips against a real backend (and need
/// an E2E mail orchestrator to run at all). This suite is deliberately hermetic: it never signs
/// anyone in, so it runs anywhere and pins the behaviour the redesign is built on —
///
///   * the submit button is dead until there is something real to submit (whitespace is not),
///   * refusals are SHOWN, in the form, next to the thing that was refused,
///   * the whole box is the tap target, not just the text inside its padding,
///   * switching between Sign in and Create account carries no stale message across.
final class AuthFormUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// `--uitest-password` swaps the SecureField for a plain one: iOS's "Use Strong Password?"
    /// takeover and the "Save Password?" panel are both untappable from XCUITest and will hang a
    /// run that types into a real secure field.
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-auth", "--uitest-password"] + extra
        app.launch()
        return app
    }

    // MARK: The disabled → enabled gate

    func testSubmitStaysDisabledUntilBothFieldsHoldSomethingReal() {
        let app = launch(["--signin-page"])
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15), "expected the sign-in form")

        let submit = app.buttons["Sign in"]
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled, "nothing typed yet — the button must not invite a tap")

        // Whitespace is not an email. This used to ENABLE the button, because the check ran on the
        // raw string while submit trimmed it, found it empty, and returned — a live button that
        // did nothing at all.
        email.tap()
        email.typeText("   ")
        app.textFields["Password"].tap()
        app.textFields["Password"].typeText("something")
        XCTAssertFalse(submit.isEnabled, "a field holding only spaces must not enable submit")

        // Real input on both — now it opens up.
        email.tap()
        email.typeText("maya@momentumco.app")
        XCTAssertTrue(submit.isEnabled, "with an address and a password, submit must be live")
    }

    // MARK: Refusals are shown

    func testInvalidAddressIsRefusedInTheFormNotSilently() {
        let app = launch(["--signin-page"])
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))

        email.tap()
        email.typeText("not-an-address")
        app.textFields["Password"].tap()
        app.textFields["Password"].typeText("whatever123")
        app.buttons["Sign in"].tap()

        XCTAssertTrue(app.staticTexts["That doesn't look like an email address."]
                        .waitForExistence(timeout: 6),
                      "a refused address has to say so, in the form")
    }

    func testShortPasswordIsRefusedOnCreate() {
        let app = launch(["--signin-create"])
        XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 15))
        // The rule is stated BEFORE it can be broken, not only after.
        XCTAssertTrue(app.staticTexts["At least 8 characters."].exists,
                      "the password rule must be visible up front")

        app.textFields["Email"].tap()
        app.textFields["Email"].typeText("maya@momentumco.app")
        app.textFields["Password"].tap()
        app.textFields["Password"].typeText("short")
        app.buttons["Create account"].tap()

        XCTAssertTrue(app.staticTexts["Passwords need at least 8 characters."]
                        .waitForExistence(timeout: 6))
    }

    // MARK: Mode switching

    func testSwitchingModesClearsTheStaleRefusal() {
        let app = launch(["--signin-page"])
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))

        email.tap()
        email.typeText("not-an-address")
        app.textFields["Password"].tap()
        app.textFields["Password"].typeText("whatever123")
        app.buttons["Sign in"].tap()
        let refusal = app.staticTexts["That doesn't look like an email address."]
        XCTAssertTrue(refusal.waitForExistence(timeout: 6))

        // Switching to Create account must not carry the old complaint across — it describes a
        // submit the athlete is no longer making.
        app.buttons["New here? Create an account"].tap()
        XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 6))
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: refusal)],
                                        timeout: 4),
                       .completed, "the refusal must clear when the mode changes")
    }

    // MARK: Tap targets

    func testTappingTheBoxFocusesTheFieldNotJustTheTextInsideIt() {
        let app = launch(["--signin-page"])
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))

        // Tap in the box's PADDING — outside the text view's own frame, but well inside the
        // rounded rectangle the athlete sees and aims at. A normalized offset on `email` would be
        // relative to the text view and could never land here, which is exactly why this has to be
        // an absolute point in app coordinates.
        let box = email.frame
        let inThePadding = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: box.minX - 8, dy: box.midY))
        XCTAssertTrue(box.minX - 8 > 0, "expected padding to the left of the text view")
        inThePadding.tap()

        // If the tap missed, there is no first responder and the text goes nowhere.
        email.typeText("edge")
        XCTAssertEqual(email.value as? String, "edge",
                       "tapping the visible box in its padding must focus the field")
    }

    // MARK: Every door is present (App Store 4.8 keeps Apple beside Google)

    func testAllTheWaysInAreOffered() {
        let app = launch(["--signin-page"])
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.appleSignInButton.exists, "SIWA must accompany Google (4.8)")
        XCTAssertTrue(app.buttons["Continue with Google"].exists)
        XCTAssertTrue(app.buttons["Continue without an account"].exists, "the guest door stays open")
        XCTAssertTrue(app.buttons["Forgot password?"].exists)
        XCTAssertTrue(app.buttons["Back"].exists)
    }
}

/// App Store 4.8 requires Sign in with Apple to accompany any third-party login. The button's
/// WORDING follows the mode Apple's own API defines — "Sign in with Apple" when signing in,
/// "Sign up with Apple" on a create-account screen (the onboarding beat starts there) — so the
/// rule has to be checked on the button's presence, not on one verb.
extension XCUIApplication {
    var appleSignInButton: XCUIElement {
        buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "with Apple")).firstMatch
    }
}
