import XCTest

/// The profile identity round-trip: edit the bio, save, and see the profile carry it (PRD §11,
/// docs/SOCIAL-LAYER.md).
///
/// Rewritten 2026-07-30. The previous version drove Progress → "Profile" → "Edit" and asserted an
/// "Appear on the map" toggle inside the editor — three surfaces that no longer exist: the profile
/// is its own tab, the button reads "Edit profile", and the map opt-in moved to Today's prompt. It
/// had been failing against the shipping app rather than testing it.
final class SocialProfileUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testEditProfileBioRoundTrip() {
        let app = XCUIApplication()
        // `--profile-edit` opens the editor directly — the same hook the avatar-strip verification
        // uses, and steadier than driving the header button.
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-edit"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Edit Profile"].waitForExistence(timeout: 25), "Editor didn't open.")

        // The Bio field, cleared and retyped — a value the profile header renders verbatim.
        // Queried by identifier, not placeholder: the placeholder stops matching once the field
        // holds a value, which made this pass on a clean container and fail on every rerun.
        let bio = app.textFields["field-Bio"]
        XCTAssertTrue(bio.waitForExistence(timeout: 5), "Bio field missing from the editor.")
        bio.tap()
        // XCUITest has no "clear field": select whatever is there and type over it.
        bio.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        let marker = "Chasing the long run."
        bio.typeText(marker)

        app.buttons["Done"].tap()

        // Saved and shown on the profile itself.
        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 10),
                      "Edited bio didn't reach the profile header.")
    }
}
