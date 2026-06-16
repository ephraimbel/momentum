import XCTest

/// Verifies the Slice-1 World tab renders the community feed with honest "Momentum community"
/// labeling (docs/SOCIAL-LAYER.md). Seeded workouts are private by default, so the feed shows the
/// curated community — which must always be present and labeled.
final class WorldFeedUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testWorldShowsLabeledCommunityFeed() {
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

        // Following segment shows its empty state, not community content.
        app.buttons["Following"].tap()
        XCTAssertTrue(app.staticTexts["Follow athletes to see them here"].waitForExistence(timeout: 5),
                      "Following empty-state missing.")
    }
}
