import XCTest

/// Verifies the Slice-1 World tab renders the community feed with honest "Momentum community"
/// labeling (docs/SOCIAL-LAYER.md). Seeded workouts are private by default, so the feed shows the
/// curated community — which must always be present and labeled.
final class WorldFeedUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testWorldShowsLabeledCommunityFeed() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route", "--reset-social"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        let world = app.tabBars.buttons["World"]
        XCTAssertTrue(world.waitForExistence(timeout: 15), "World tab not found.")
        world.tap()

        // A seeded community post should render…
        XCTAssertTrue(app.staticTexts["Sunrise tempo"].waitForExistence(timeout: 5),
                      "Community feed post not shown.")
        // …and be honestly labeled as community content (badge has accessibility label).
        let badge = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Momentum community'")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "Community label missing on seeded content.")

    }

    func testCommentOnPost() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route", "--reset-social"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        let world = app.tabBars.buttons["World"]
        XCTAssertTrue(world.waitForExistence(timeout: 15)); world.tap()

        // Open comments on the first post.
        let commentsBtn = app.buttons["Comments"].firstMatch
        XCTAssertTrue(commentsBtn.waitForExistence(timeout: 5), "Comment button not found.")
        commentsBtn.tap()

        let field = app.textViews["Add a comment…"].firstMatch
        let field2 = app.textFields["Add a comment…"].firstMatch
        let input = field.exists ? field : field2
        XCTAssertTrue(input.waitForExistence(timeout: 5), "Comment composer not found.")
        input.tap(); input.typeText("Strong work")
        app.buttons["Post comment"].tap()

        XCTAssertTrue(app.staticTexts["Strong work"].waitForExistence(timeout: 5),
                      "Posted comment didn't appear.")
    }

    func testBlockRemovesAthleteFromFeed() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route", "--reset-social"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        let world = app.tabBars.buttons["World"]
        XCTAssertTrue(world.waitForExistence(timeout: 15)); world.tap()

        // Open the profile of whichever athlete leads the feed (date-sorted, so order isn't fixed).
        let lead = app.buttons.matching(identifier: "feed-author").firstMatch
        XCTAssertTrue(lead.waitForExistence(timeout: 5), "No author byline in the feed.")
        let leadName = lead.label
        lead.tap()

        app.buttons["More"].tap()                         // toolbar ⋯ menu
        app.buttons["Block \(leadName)"].tap()

        // Back on the feed, a different athlete now leads — the blocked one's post is gone.
        let newLead = app.buttons.matching(identifier: "feed-author").firstMatch
        XCTAssertTrue(newLead.waitForExistence(timeout: 5), "Feed empty after block.")
        XCTAssertNotEqual(newLead.label, leadName, "Blocked athlete still leads the feed.")
    }

    func testRespectReaction() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route", "--reset-social"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        let world = app.tabBars.buttons["World"]
        XCTAssertTrue(world.waitForExistence(timeout: 15)); world.tap()

        // Tap a respect button if any post is un-reacted; end state must show a "Respected" reaction.
        let respect = app.buttons["Respect"].firstMatch
        if respect.waitForExistence(timeout: 5) { respect.tap() }
        XCTAssertTrue(app.buttons["Respected"].firstMatch.waitForExistence(timeout: 5),
                      "Respect reaction didn't register.")
    }

    func testFollowAthleteSurfacesInFollowing() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route", "--reset-social"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        let world = app.tabBars.buttons["World"]
        XCTAssertTrue(world.waitForExistence(timeout: 15)); world.tap()

        // Open the profile of whichever athlete leads the feed via their author byline.
        let lead = app.buttons.matching(identifier: "feed-author").firstMatch
        XCTAssertTrue(lead.waitForExistence(timeout: 5), "No author byline in the feed.")
        lead.tap()

        // Ensure we end up Following them. After --reset-social we start un-followed, so the button
        // reads "Follow <name>" (note the trailing space — distinct from the "Following …" state).
        let followBtn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Follow '")).firstMatch
        XCTAssertTrue(followBtn.waitForExistence(timeout: 5), "Follow button not found on profile.")
        followBtn.tap()

        // Back to the feed, switch to Following — a followed athlete's post should be there.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Following"].tap()
        let followedPost = app.buttons.matching(identifier: "feed-author").firstMatch
        XCTAssertTrue(followedPost.waitForExistence(timeout: 5),
                      "Followed athlete's post not in Following feed.")
    }
}
