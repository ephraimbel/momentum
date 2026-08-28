import XCTest

/// The community home (2026-08-25, the Share Aura structure in our theme), end to end in the sim:
/// Find people → the Following row (ringed faces, "Your day" first) → Explore with the Friends |
/// Global scope tabs and the wall. A ring opens that person's day in the pager; Find people opens
/// the in-place search.
final class CommunityFeedUITests: XCTestCase {

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

    /// The base launch: community face, a few known follows, silhouette maps (accessibility
    /// snapshots realize every lazy row; live Mapbox renders time the queries out).
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-community", "--reset-social",
                               "--ui-test-social", "--seed-follows"] + extra
        monitor()
        app.launch()
        return app
    }

    func testHomeReadsTopDown() throws {
        let app = launch()

        XCTAssertTrue(app.buttons["Find people"].waitForExistence(timeout: 30), "Find people field missing.")
        XCTAssertTrue(app.buttons["Find athletes to follow"].exists, "Add-person glass circle missing.")
        XCTAssertTrue(app.staticTexts["Following"].exists, "Following heading missing.")
        // "Your day" leads the row (ringed when the athlete trained today: label carries the state).
        let you = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Your day'")).firstMatch
        XCTAssertTrue(you.exists, "'Your day' face missing.")
        // A seeded follow shows as a face labelled by first name.
        let maya = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Maya'")).firstMatch
        XCTAssertTrue(maya.exists, "Followed athlete's face missing from the row.")
        XCTAssertTrue(app.staticTexts["Explore"].exists, "Explore heading missing.")
        XCTAssertTrue(app.buttons["Friends"].exists && app.buttons["Global"].exists, "Scope tabs missing.")
        attach(app, name: "community-home")

        // Friends scope: only followed athletes' posts; the wall still renders tiles.
        app.buttons["Friends"].tap()
        let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'mi' OR label CONTAINS[c] 'lb' OR label CONTAINS ':'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "Friends wall rendered no tiles.")
        attach(app, name: "community-friends")
    }

    func testRingOpensTheirDayInThePager() throws {
        // --open-ring drives the first ringed face's handler (taps on the row are unreliable in
        // the sim); the pager's Close and a byline prove the day opened.
        let app = launch(["--open-ring"])
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 30), "Ring did not open the pager.")
        let byline = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View '")).firstMatch
        XCTAssertTrue(byline.waitForExistence(timeout: 5), "Pager page has no byline.")
        attach(app, name: "community-ring-pager")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Find people"].waitForExistence(timeout: 5), "Did not return to the home.")
    }

    func testFindPeopleOpensInPlaceSearch() throws {
        let app = launch()
        app.buttons["Find people"].tap(after: 30)
        let field = app.textFields["Search by name or @handle"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Find people did not open the search.")
        field.tap()
        field.typeText("@bennettbuilt")
        XCTAssertTrue(app.staticTexts["Theo Bennett"].waitForExistence(timeout: 5),
                      "@handle search did not surface the athlete.")
        attach(app, name: "community-search")
        app.buttons["Cancel search"].tap()
        XCTAssertTrue(app.buttons["Find people"].waitForExistence(timeout: 5), "Cancel did not return to the home.")
    }
}

private extension XCUIElement {
    /// Wait then tap — keeps multi-step flows readable.
    func tap(after timeout: TimeInterval) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "Element \(self) not found within \(timeout)s.")
        tap()
    }
}
