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

    func testAvatarOpensProfile() {
        let app = launch()
        let avatar = app.buttons["Your profile"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 15), "Avatar missing from header.")
        avatar.tap()
        // The profile sheet hosts the full ProfileScreen (media grid) — give it room to appear.
        let opened = app.buttons["Done"].waitForExistence(timeout: 30)
        if !opened {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(opened, "Profile sheet did not open from the avatar.")
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
