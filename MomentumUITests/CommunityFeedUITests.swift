import XCTest

/// The Community tab (docs/SOCIAL-LAYER.md, 2026-07-09) end-to-end in the sim: the feed renders
/// badged community posts under the Following|Everyone scope bar, a community byline pushes that
/// athlete's profile (with Follow), and the post-workout save screen carries the share moment
/// (visibility picker + what-others-see hint).
final class CommunityFeedUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testFeedScopesAndBylineNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--community-tab", "--reset-social"]
        // Without a monitor, the notifications permission alert (seeded plan reminders) blocks
        // element resolution mid-test and XCTest's blind dismissal taps land on the tab bar.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()

        // Everyone scope (default): community posts present, each with a tappable byline (the badge
        // lives inside the byline button, so the button's "View …'s profile" label is the anchor).
        XCTAssertTrue(app.buttons["Everyone"].waitForExistence(timeout: 20), "Scope bar not found.")
        app.buttons["Everyone"].tap()   // harmless re-select; triggers the monitor if an alert is up
        let bylines = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View '"))
        XCTAssertTrue(bylines.firstMatch.waitForExistence(timeout: 10),
                      "No community bylines — community posts missing from Everyone.")
        attach(app, name: "community-everyone")

        // A community byline opens that athlete's profile (Follow lives there).
        bylines.firstMatch.tap()
        // The follow button carries the athlete's name in its label ("Follow Maya Rivera").
        let follow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Follow'")).firstMatch
        if !follow.waitForExistence(timeout: 10) {
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "hierarchy-after-byline-tap"; dump.lifetime = .keepAlways; add(dump)
            XCTFail("Byline tap did not open an athlete profile.")
        }
        attach(app, name: "athlete-profile-from-feed")
        app.navigationBars.buttons.firstMatch.tap()   // back to the feed

        // Following scope with no follows: the no-shame empty state, with a route back to Everyone.
        app.buttons["Following"].tap()
        XCTAssertTrue(app.staticTexts["Your people will show up here"].waitForExistence(timeout: 5),
                      "Following empty state not shown with zero follows.")
        attach(app, name: "community-following-empty")
        app.buttons["Find athletes"].tap()
        XCTAssertTrue(bylines.firstMatch.waitForExistence(timeout: 5),
                      "'Find athletes' did not flip the scope back to Everyone.")
    }

    func testSaveScreenCarriesTheShareMoment() {
        let app = XCUIApplication()
        // `--ui-test-strength` opens Today in strength; `--ui-test-route` self-authorizes location.
        app.launchArguments = ["--seed-demo", "--ui-test-strength", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()   // trigger the interruption monitor if a permission alert is up

        // Log one set so Finish enables (same path as StrengthLogUITests).
        app.buttons["Start workout"].firstMatch.tap(after: 20)
        app.staticTexts["Barbell Bench Press"].firstMatch.tap(after: 15)
        app.buttons["Add 1"].firstMatch.tap(after: 5)
        app.buttons["Log set"].firstMatch.tap(after: 15)
        app.buttons["Finish"].firstMatch.tap(after: 5)

        // The save screen: declared-intent prompt + the visibility picker with its plain-words hint.
        let visibility = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Workout visibility'")).firstMatch
        XCTAssertTrue(visibility.waitForExistence(timeout: 15), "Save screen has no visibility picker.")
        XCTAssertTrue(app.textFields["How did it go — and why did this one matter?"]
            .waitForExistence(timeout: 5), "Save screen is missing the declared-intent prompt.")
        attach(app, name: "save-share-moment")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

private extension XCUIElement {
    /// Wait then tap — keeps multi-step flows readable.
    func tap(after timeout: TimeInterval) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "Element \(self) not found within \(timeout)s.")
        tap()
    }
}
