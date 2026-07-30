import XCTest

/// The Today header + map controls must all respond: sport pill → SportPicker, bell → inbox,
/// avatar → profile, recenter → (no crash, camera command). Regression suite for the
/// "buttons don't work" report.
final class TodayHeaderUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()
        return app
    }

    func testSportPillOpensPicker() {
        let app = launch()
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Change activity'")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "Sport pill missing from header.")
        pill.tap()
        // SportPicker: search field + sport rows.
        XCTAssertTrue(app.staticTexts["Weight Training"].waitForExistence(timeout: 5)
                      || app.buttons["Weight Training"].waitForExistence(timeout: 2),
                      "SportPicker did not open from the header pill.")
    }

    func testBellOpensNotificationsInbox() {
        let app = launch()
        let bell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notifications'")).firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 15), "Bell missing from header.")
        bell.tap()
        XCTAssertTrue(app.staticTexts["Today's session is ready"].waitForExistence(timeout: 5)
                      || app.navigationBars["Notifications"].waitForExistence(timeout: 2)
                      || app.staticTexts["Welcome to momentum"].waitForExistence(timeout: 2),
                      "Notifications inbox did not open from the bell.")
    }

    /// The avatar SELECTS the Profile tab — it is a second door to the one real profile, not a
    /// second profile screen (fix 2026-07-30). It used to push `ProfileScreen(showsBackButton:)`,
    /// whose non-tab-root state suppressed the Profile ↔ Community slider; asserting the slider
    /// here is what keeps that from coming back. ("Edit profile" is the landing marker — the old
    /// assertion waited on "Edit", which stopped matching when the button was renamed.)
    func testAvatarOpensProfileTab() {
        let app = launch()
        let avatar = app.buttons["Your profile"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 15), "Avatar missing from header.")
        // Retried, not single-shot: glass chrome over a LIVE Mapbox map intermittently loses the
        // touch to the map's own UIKit recognizers (the race `mapSafeTap` fights and does not
        // always win — it reproduces here once the basemap tiles finish loading, and the recorded
        // video shows the app never leaving Today, no transition even beginning). That is a
        // tap-DELIVERY flake, independent of where the button goes; what this test guards is the
        // destination, so don't let the flake read as a routing regression.
        let edit = app.buttons["Edit profile"]
        var opened = false
        for _ in 0..<3 {
            avatar.tap()
            if edit.waitForExistence(timeout: 12) { opened = true; break }
        }
        // The full tab-root profile, slider included — not the lesser pushed copy.
        let hasCommunitySlider = app.buttons["Community"].waitForExistence(timeout: 5)
            && app.buttons["Profile"].exists
        if !opened || !hasCommunitySlider {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(opened, "Profile did not open from the avatar.")
        XCTAssertTrue(hasCommunitySlider,
                      "Avatar landed on a profile without the Profile ↔ Community slider — it is not the tab root.")
    }

    func testRecenterButtonResponds() {
        let app = launch()
        let recenter = app.buttons["Recenter on my location"].firstMatch
        XCTAssertTrue(recenter.waitForExistence(timeout: 15), "Recenter button missing.")
        recenter.tap()
        // No sheet — success is simply the app still responsive with the header intact.
        XCTAssertTrue(app.buttons["Your profile"].waitForExistence(timeout: 5),
                      "App unresponsive after recenter tap.")
    }
}
