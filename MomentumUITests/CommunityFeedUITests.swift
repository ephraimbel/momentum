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

    func testFeedScopesAndBylineNavigation() throws {
        throw XCTSkip("Community is back-burnered for v1 (2026-07-16) — suite returns with the feed.")
        let app = XCUIApplication()
        // --ui-test-social keeps feed maps as instant silhouettes; XCTest's accessibility snapshot
        // realizes every lazy row, and a fleet of live Mapbox renders times the queries out.
        app.launchArguments = ["--seed-demo", "--community-tab", "--reset-social", "--ui-test-social"]
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
        app.tap()   // flush the notifications permission alert through the monitor up front
        sleep(1)

        // Everyone scope (default): community posts present, each with a tappable byline (the badge
        // lives inside the byline button, so the button's "View …'s profile" label is the anchor).
        XCTAssertTrue(app.buttons["Everyone"].waitForExistence(timeout: 30), "Scope bar not found.")
        app.buttons["Everyone"].tap()   // harmless re-select
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

        // Following scope with no follows: the no-shame empty state routes into athlete search.
        app.buttons["Following"].tap()
        XCTAssertTrue(app.staticTexts["Your people will show up here"].waitForExistence(timeout: 5),
                      "Following empty state not shown with zero follows.")
        attach(app, name: "community-following-empty")
        app.buttons["Find athletes"].firstMatch.tap()
        XCTAssertTrue(app.textFields["Search by name or @handle"].waitForExistence(timeout: 5),
                      "'Find athletes' did not open the athlete search.")
    }

    /// Athlete search: name/@handle queries surface matches with a working Follow; and tapping a
    /// post's body opens the full-page reading view (fullScreenCover, 2026-07-10 — the sheet
    /// presentation was clipping the post on device).
    func testSearchFollowAndFullPagePostDetail() throws {
        throw XCTSkip("Community is back-burnered for v1 (2026-07-16) — suite returns with the feed.")
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--community-tab", "--reset-social", "--ui-test-social"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()   // flush the notifications permission alert through the monitor up front
        sleep(1)

        // Wait for the feed to settle before the first real tap — the magnifier exists from the
        // first frame, but tapping while the alert/monitor dance is live invalidates the event.
        XCTAssertTrue(app.buttons["Everyone"].waitForExistence(timeout: 30), "Community did not load.")

        // Header magnifier → search sheet, seeded suggestions up front.
        app.buttons["Find athletes"].firstMatch.tap(after: 20)
        let field = app.textFields["Search by name or @handle"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Search field missing.")
        XCTAssertTrue(app.staticTexts["SUGGESTED"].exists, "Empty-query suggestions missing.")
        field.tap()
        field.typeText("Maya Rivera")
        XCTAssertTrue(app.staticTexts["Maya Rivera"].waitForExistence(timeout: 5),
                      "Name search did not surface the featured athlete.")
        app.buttons["Follow Maya Rivera"].firstMatch.tap(after: 3)
        XCTAssertTrue(app.buttons["Unfollow Maya Rivera"].waitForExistence(timeout: 3),
                      "Follow from search results did not stick.")
        attach(app, name: "find-athletes-results")
        app.buttons["Done"].tap()

        // @handle search matches too (the strip-@ path).
        app.buttons["Find athletes"].firstMatch.tap(after: 5)
        field.tap(after: 3)
        field.typeText("@coachtheo")
        XCTAssertTrue(app.staticTexts["Theo Bennett"].waitForExistence(timeout: 5),
                      "@handle search did not surface the athlete.")
        app.buttons["Done"].tap()

        // Post body → full-page reading view (Done closes it).
        let postBody = app.buttons.matching(identifier: "post-body").firstMatch
        postBody.tap(after: 10)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 8), "Post detail did not open.")
        attach(app, name: "post-detail-full-page")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Everyone"].waitForExistence(timeout: 5), "Did not return to the feed.")
    }

    func testSaveScreenCarriesTheShareMoment() throws {
        throw XCTSkip("Community is back-burnered for v1 (2026-07-16) — suite returns with the feed.")
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
