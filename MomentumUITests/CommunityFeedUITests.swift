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

    // MARK: Comment threads

    /// Walks the pager and opens the thread on every post that has one, in both appearances. The
    /// screenshots are the point (a thread has to READ like people typed it), so each one is
    /// attached alongside a printed transcript of every line on screen — the transcript is how the
    /// copy gets judged as text, the shot is how it gets judged as a page.
    func testCommentThreadsReadLikePeopleLight() throws { try walkComments(appearance: "light") }
    func testCommentThreadsReadLikePeopleDark() throws { try walkComments(appearance: "dark") }

    private func walkComments(appearance: String) throws {
        // Starts halfway down the 400-post wall on purpose. The top of the wall is minutes to a
        // few hours old, and a post nobody has seen yet correctly has almost no thread (comment
        // volume follows the respect count, which grows with the post's age). Index 200 is roughly
        // a day old: that is where the conversations are.
        let app = launch(["--open-post", "200", "-com.momentum.appearance", appearance])
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 60), "Pager did not open.")

        var opened = 0
        for page in 0..<24 {
            // Never break out on a missing rail: a page that has not laid out yet must cost one
            // swipe, not the rest of the walk (that turned a passing run into "1 thread" once).
            let bubble = app.buttons.matching(NSPredicate(format: "label == %@", "Comments"))
                .allElementsBoundByIndex.first(where: \.isHittable)
            let count = bubble.flatMap { Int($0.value as? String ?? "") } ?? 0
            if let bubble, count > 0 {
                bubble.tap()
                let done = app.buttons["Done"]
                XCTAssertTrue(done.waitForExistence(timeout: 10), "Comments sheet did not open on page \(page).")
                let lines = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
                // The rail promised a number; the list has to show exactly that many.
                let header = lines.first { $0.hasSuffix(" comments") || $0 == "1 comment" } ?? "?"
                print("THREAD [\(appearance)] page \(page) rail=\(count) header=\(header) :: "
                      + lines.joined(separator: " | "))
                XCTAssertEqual(header, count == 1 ? "1 comment" : "\(count) comments",
                               "Rail said \(count); the sheet says '\(header)'.")
                attach(app, name: "comments-\(appearance)-\(String(format: "%02d", page))")
                opened += 1
                done.tap()
                XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "Sheet did not dismiss.")
            }
            app.swipeUp()
        }
        XCTAssertGreaterThanOrEqual(opened, 4, "Only \(opened) threads across 24 posts; the wall reads empty.")
    }
}

private extension XCUIElement {
    /// Wait then tap — keeps multi-step flows readable.
    func tap(after timeout: TimeInterval) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "Element \(self) not found within \(timeout)s.")
        tap()
    }
}
