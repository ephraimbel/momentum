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

        XCTAssertTrue(app.staticTexts["Sunrise tempo"].waitForExistence(timeout: 5))
        app.staticTexts["Sunrise tempo"].tap()           // open Maya's profile

        app.buttons["More"].tap()                         // toolbar ⋯ menu
        app.buttons["Block Maya Rivera"].tap()

        // Back on the feed, her post is gone.
        XCTAssertFalse(app.staticTexts["Sunrise tempo"].waitForExistence(timeout: 3),
                       "Blocked athlete's post still shown.")
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

        // Open Maya's profile from her post.
        let post = app.staticTexts["Sunrise tempo"]
        XCTAssertTrue(post.waitForExistence(timeout: 5)); post.tap()

        // Ensure we end up Following her (deterministic regardless of persisted state).
        let followBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Maya Rivera'")).firstMatch
        XCTAssertTrue(followBtn.waitForExistence(timeout: 5), "Follow button not found on profile.")
        if followBtn.label.hasPrefix("Follow ") { followBtn.tap() }

        // Back to the feed, switch to Following — her post should be there.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Following"].tap()
        XCTAssertTrue(app.staticTexts["Sunrise tempo"].waitForExistence(timeout: 5),
                      "Followed athlete's post not in Following feed.")
    }
}
