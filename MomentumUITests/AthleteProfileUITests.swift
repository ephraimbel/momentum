import XCTest

/// Visited athlete profiles mirror the athlete's own profile structure (user call 2026-07-10):
/// identity + posts/followers/following trio + follow + Grid|Highlights faces with the same tile
/// grammar. Dumps PNGs for visual inspection.
final class AthleteProfileUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
    }

    func testVisitedProfileMirrorsOwnStructure() {
        let app = XCUIApplication()
        // --athlete-profile opens the first community athlete deterministically (feed taps are
        // flaky under the glass bar; the entry point itself is covered by CommunityView).
        app.launchArguments = ["--seed-demo", "--community-tab", "--athlete-profile"]
        app.launch()

        // The own-profile grammar: follow button, trio labels, and the Grid|Highlights tab bar.
        let follow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Follow'")).firstMatch
        XCTAssertTrue(follow.waitForExistence(timeout: 10), "Follow button missing.")
        let trio = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'followers'")).firstMatch
        XCTAssertTrue(trio.exists, "Posts/Followers/Following trio missing.")
        XCTAssertTrue(app.buttons["Grid"].exists && app.buttons["Highlights"].exists, "Grid/Highlights faces missing.")
        dump(app, "verify_athlete_grid")

        app.buttons["Highlights"].tap()
        sleep(1)
        dump(app, "verify_athlete_highlights")
    }
}
