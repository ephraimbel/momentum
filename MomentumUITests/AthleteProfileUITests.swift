import XCTest

/// Visited athlete profiles are twins of the athlete's own (2026-08-25, the shared `ProfileHero`):
/// cover → ringed PFP + trio → name → handle → followers line → chips → pills → Grid|Highlights.
/// Follow is the page's one primary action; Nudge appears only on a followed athlete with no ring.
final class AthleteProfileUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func monitor() {
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testVisitedProfileMirrorsOwnStructure() throws {
        let app = XCUIApplication()
        // --athlete-profile opens the first community athlete deterministically (Maya Rivera).
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-community", "--reset-social",
                               "--ui-test-social", "--athlete-profile"]
        monitor()
        app.launch()

        // The hero grammar: Follow (ink primary), the followers line, and the Grid|Highlights faces.
        let follow = app.buttons["Follow Maya Rivera"]
        XCTAssertTrue(follow.waitForExistence(timeout: 20), "Follow button missing on the visited profile.")
        let followers = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'followers'")).firstMatch
        XCTAssertTrue(followers.exists, "Followers · Following line missing.")
        XCTAssertTrue(app.buttons["Grid"].exists && app.buttons["Highlights"].exists, "Grid/Highlights faces missing.")
        XCTAssertTrue(app.buttons["Back"].exists && app.buttons["More"].exists, "Glass chrome (Back · More) missing on the cover.")
        attach(app, name: "athlete-hero")

        // Follow flips the pill to the quiet state and keeps the athlete's name in the label.
        follow.tap()
        XCTAssertTrue(app.buttons["Following Maya Rivera. Tap to unfollow."].waitForExistence(timeout: 5),
                      "Follow did not flip to Following.")

        app.buttons["Highlights"].tap()
        XCTAssertTrue(app.staticTexts["LIFETIME"].waitForExistence(timeout: 5), "Highlights face did not open.")
        attach(app, name: "athlete-highlights")
    }

    /// Nudge is care, not pressure: it exists only for a followed athlete with no ring (no post
    /// in the last 24h), and a tap spends it for the day.
    func testNudgeAppearsOnlyForIdleMutualsAndSpendsForTheDay() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-community", "--reset-social",
                               "--ui-test-social", "--athlete-profile-stale"]
        monitor()
        app.launch()

        let nudge = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Nudge '")).firstMatch
        XCTAssertTrue(nudge.waitForExistence(timeout: 20), "Nudge pill missing on a followed, idle athlete.")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Following '")).firstMatch.exists,
                      "The stale athlete should already be followed (the debug hook follows on open).")
        attach(app, name: "athlete-nudge-available")
        nudge.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Nudged '")).firstMatch
            .waitForExistence(timeout: 5), "Nudge did not flip to Nudged.")
        attach(app, name: "athlete-nudged")
    }
}
