import XCTest

/// Verifies the Slice-0 social surface: open the profile, edit it, flip a privacy toggle, and see the
/// profile's privacy summary reflect the opt-in (PRD §11, docs/SOCIAL-LAYER.md).
final class SocialProfileUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testEditProfilePrivacyRoundTrip() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // Progress tab → Profile.
        let progress = app.tabBars.buttons["Progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 15), "Progress tab not found.")
        progress.tap()

        let profileButton = app.buttons["Profile"]
        XCTAssertTrue(profileButton.waitForExistence(timeout: 5), "Profile entry not found.")
        profileButton.tap()

        // Profile screen has Edit.
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Profile didn't open.")
        edit.tap()

        XCTAssertTrue(app.navigationBars["Edit Profile"].waitForExistence(timeout: 5), "Editor didn't open.")

        // Force the map opt-in ON (deterministic regardless of any persisted state from prior runs).
        let mapToggle = app.switches["Appear on the map"]
        XCTAssertTrue(mapToggle.waitForExistence(timeout: 5), "Map toggle not found.")
        if (mapToggle.value as? String) == "0" { mapToggle.tap() }

        app.buttons["Done"].tap()

        // The profile's privacy summary should now mention the map.
        let onMap = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'map'")).firstMatch
        XCTAssertTrue(onMap.waitForExistence(timeout: 5), "Privacy summary didn't reflect the map opt-in.")
    }
}
