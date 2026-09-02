import XCTest

/// The community wall's cross-view agreement, driven by real taps (owner ask 2026-08-28: "make
/// sure every little detail about every aspect of the community makes sense"). The fakeness a user
/// feels is almost always two surfaces disagreeing about the same fact — a tile that opens onto a
/// different post, a name that changes between a list and the page it pushes, a "Suggested" column
/// that keeps offering people you already follow.
///
/// `--ui-test-social` keeps the instant route silhouettes: XCUITest realizes every lazy cell at
/// once, and a hundred queued Mapbox renders starve the run.
final class CommunityWallUITests: XCTestCase {

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

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-community",
                               "--ui-test-social"] + extra
        monitor()
        app.launch()
        return app
    }

    /// A wall tile carries "who, what, how far" in its accessibility label; the page it opens
    /// carries the same three. If they ever disagree the grid is lying about what's behind it —
    /// the exact class of bug that made every tile open on Bianca (2026-07-29).
    func testTileAndThePageItOpensTellTheSameStory() {
        let app = launch(["--feed-global", "--reset-social"])

        let query = app.buttons.matching(NSPredicate(format: "label CONTAINS ' mi · '"))
        let deadline = Date().addingTimeInterval(30)
        var visibleTile: XCUIElement?
        while Date() < deadline, visibleTile == nil {
            // `isHittable` remains true when only a tile's last few pixels peek out from behind
            // the pinned Community header. Tapping that stale sliver lands on the header, so the
            // pager never opens and the test misreports a wrong-post routing bug. Exercise the
            // gesture a person can actually make: a whole tile inside the unobscured wall, clear
            // of both the header and the floating tab bar.
            let safeTop = app.frame.minY + 120
            let safeBottom = app.frame.maxY - 120
            visibleTile = query.allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.minY >= safeTop && $0.frame.maxY <= safeBottom
            }
            if visibleTile == nil { usleep(100_000) }
        }
        guard let tile = visibleTile else {
            return XCTFail("No visible routed tile on the community wall.")
        }
        let label = tile.label
        let author = String(label.split(separator: ",").first ?? "")
        guard let distance = Self.distanceToken(in: label) else {
            return XCTFail("Couldn't read a distance out of the tile label '\(label)'.")
        }
        attach(app, name: "wall")

        tile.tap()

        // Page one is the post that was tapped: same author on the byline, same distance in the
        // stat row.
        let byline = app.buttons["View \(author)'s profile"]
        XCTAssertTrue(byline.waitForExistence(timeout: 15),
                      "The pager opened on someone other than '\(author)' (tile said: \(label)).")
        let distanceCell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Distance: \(distance)")).firstMatch
        XCTAssertTrue(distanceCell.waitForExistence(timeout: 10),
                      "The page's distance doesn't match the tile's \(distance).")
        attach(app, name: "page")
    }

    /// Suggested has to react to what the athlete does. A follow made from this very list used to
    /// leave the row offering "Follow" forever on the next visit — the surest sign nothing here
    /// registers. The row stays put for THIS visit (a row that vanishes under the thumb makes a
    /// mis-tap unrecoverable) and is gone the next time the search opens.
    func testSuggestedStopsOfferingPeopleYouAlreadyFollow() {
        let app = launch(["--reset-social", "--find-athletes"])

        XCTAssertTrue(app.staticTexts["SUGGESTED"].waitForExistence(timeout: 30), "Suggested list never appeared.")
        let follow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Follow '")).firstMatch
        XCTAssertTrue(follow.waitForExistence(timeout: 10), "No follow pill in Suggested.")
        let name = String(follow.label.dropFirst("Follow ".count))
        follow.tap()

        XCTAssertTrue(app.buttons["Unfollow \(name)"].waitForExistence(timeout: 5),
                      "Follow tap didn't register for \(name).")
        XCTAssertTrue(app.buttons["View \(name)'s profile"].exists,
                      "\(name)'s row vanished the moment they were followed — a mis-tap can't be undone.")
        attach(app, name: "suggested-after-follow")

        // Next visit: they've been suggested, and taken.
        app.terminate()
        let again = launch(["--find-athletes"])
        XCTAssertTrue(again.staticTexts["SUGGESTED"].waitForExistence(timeout: 30), "Suggested list never re-appeared.")
        XCTAssertFalse(again.buttons["Follow \(name)"].exists,
                       "Suggested is still offering \(name), who is already followed.")
        XCTAssertFalse(again.buttons["Unfollow \(name)"].exists,
                       "Suggested kept \(name) across visits instead of topping up with someone new.")
    }

    /// The walk a curious user actually takes: an athlete → their followers → one of those people.
    /// Every hop has to agree about who it is — the list row's name, the page it pushes, and the
    /// graph list that page pushes in turn.
    func testWalkingFromAnAthleteIntoTheirFollowersKeepsOneIdentity() {
        let app = launch(["--reset-social", "--athlete-profile", "sub3maya", "--athlete-graph"])

        // Hop 1: the list belongs to the athlete whose profile pushed it.
        XCTAssertTrue(app.navigationBars["Maya Rivera"].waitForExistence(timeout: 30),
                      "Maya's follower list didn't open under her own name.")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View '")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Maya's follower list has no rows.")
        let follower = String(row.label.dropFirst("View ".count).dropLast("'s profile".count))
        XCTAssertFalse(follower.isEmpty, "Couldn't read a name out of '\(row.label)'.")
        attach(app, name: "maya-followers")

        // Hop 2: the row opens THAT person's page, under THAT person's name.
        row.tap()
        let followPill = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                        "Follow \(follower)", "Following \(follower)")).firstMatch
        XCTAssertTrue(followPill.waitForExistence(timeout: 15),
                      "Row said '\(follower)' but the page it opened doesn't carry that name.")

        // Hop 3: their own graph opens under their own name, so the walk can keep going.
        // Bound by hittability, not `firstMatch`: Maya's page is still on the stack underneath and
        // its own counts line stays queryable.
        let countsQuery = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'followers,' AND label CONTAINS[c] 'following'"))
        XCTAssertTrue(countsQuery.firstMatch.waitForExistence(timeout: 10),
                      "\(follower) has no followers line to walk into.")
        guard let counts = countsQuery.allElementsBoundByIndex.first(where: \.isHittable) else {
            return XCTFail("\(follower)'s followers line isn't reachable.")
        }
        counts.tap()
        XCTAssertTrue(app.navigationBars[follower].waitForExistence(timeout: 15),
                      "\(follower)'s graph didn't open under their own name.")
        attach(app, name: "follower-graph")
    }

    // MARK: Helpers

    /// "Rosa Lindqvist, Morning run, 5.3 mi · 54:04, 3 minutes ago" -> "5.3 mi".
    private static func distanceToken(in label: String) -> String? {
        guard let unit = label.range(of: " mi · "),
              let number = label[label.startIndex..<unit.lowerBound].split(separator: " ").last
        else { return nil }
        return "\(number) mi"
    }
}
