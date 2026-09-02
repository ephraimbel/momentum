import XCTest

/// The community interactions, driven through the real UI (owner ask 2026-08-29: "make everything
/// work as a real social page"). Each test pins one of the three ways a social surface reads as
/// fake — a control that does nothing, a control that forgets, and a control whose effect one
/// screen shows and another doesn't.
///
/// These run with no Supabase session, which is exactly the guest/offline path: every push
/// no-ops, so what they prove is that the local half is honest on its own.
final class SocialInteractionUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    // MARK: Comments

    /// Post a comment, see it immediately, and find it still there after a cold start. The store
    /// keys comments by post id, and a seeded community post's id is derived from (handle, slot) —
    /// so this also proves those ids are stable across launches. If they weren't, a comment on a
    /// community post could never survive a relaunch no matter how well the store persisted.
    ///
    /// The anchor is Maya's newest PROFILE GRID tile, not the wall's index 0. The wall is sorted
    /// by recency against `Date()`, so "the first post" is a different post on every launch —
    /// measured, not assumed: two launches 16 seconds apart opened Andre Lindqvist's ride and then
    /// Lucia Iyer's upper-body session. Her grid's first tile is ledger slot 0, which is stable by
    /// construction.
    func testCommentAppearsImmediatelyAndSurvivesRelaunch() {
        let app = XCUIApplication()
        let text = "Nine miles before the heat"
        let args = ["--seed-demo", "--profile-tab", "--profile-community",
                    "--athlete-profile", "sub3maya"]

        app.launchArguments = args + ["--reset-social"]
        app.launch()

        openNewestTile(app)
        openComments(app)
        let field = commentField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Comment composer never appeared.")
        let before = commentCount(app)

        field.tap()
        field.typeText(text)
        app.buttons["Post comment"].tap()

        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 5),
                      "The comment didn't appear in the thread it was posted to.")
        // The header count describes the list under it — a thread that gains a row and keeps its
        // number is the same small lie as a follower count that doesn't move.
        XCTAssertEqual(commentCount(app), before + 1,
                       "The comment count didn't move with the comment.")

        // MARK: Cold start — the comment is still on the same post
        app.terminate()
        app.launchArguments = args        // no --reset-social: it must INHERIT the comment
        app.launch()
        openNewestTile(app)
        openComments(app)
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 15),
                      "The comment did not survive a relaunch.")
        XCTAssertEqual(commentCount(app), before + 1,
                       "The count didn't survive the relaunch with the comment.")
    }

    // MARK: Blocking

    /// Blocking somebody you follow has to unfollow them too, or their face keeps its place in the
    /// ring row and the follow list while every post of theirs is hidden — the app disagreeing
    /// with itself about whether that person exists. Asserted after a cold start, so it is the
    /// persisted state being checked, not a lucky frame.
    func testBlockingAlsoUnfollowsAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--reset-social", "--profile-tab",
                               "--profile-community", "--athlete-profile", "sub3maya"]
        app.launch()

        let follow = app.buttons["Follow Maya Rivera"]
        XCTAssertTrue(follow.waitForExistence(timeout: 25), "Athlete profile didn't open.")
        follow.tap()
        XCTAssertTrue(app.buttons["Following Maya Rivera. Tap to unfollow."].waitForExistence(timeout: 5),
                      "Follow didn't register.")

        app.buttons["More"].tap()
        let block = app.buttons["Block Maya Rivera"]
        XCTAssertTrue(block.waitForExistence(timeout: 5), "Block action missing from the ••• menu.")
        block.tap()

        // Cold start: the block took the follow with it.
        app.terminate()
        app.launchArguments = ["--seed-demo", "--profile-tab"]
        app.launch()
        XCTAssertTrue(app.buttons["0 followers, 0 following"].waitForExistence(timeout: 25),
                      "Blocking left the athlete in the Following count.")
    }

    // MARK: Search

    /// Typing somebody's exact handle puts THAT person first, and a query nobody matches says so
    /// instead of showing a blank column.
    func testSearchFindsAnExactHandleAndSaysWhenNobodyMatches() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--reset-social", "--profile-tab",
                               "--profile-community", "--find-athletes",
                               "--find-query", "sub3maya"]
        app.launch()
        XCTAssertTrue(app.buttons["View Maya Rivera's profile"].waitForExistence(timeout: 25),
                      "Searching an exact handle didn't surface its owner.")

        app.terminate()
        app.launchArguments = ["--seed-demo", "--reset-social", "--profile-tab",
                               "--profile-community", "--find-athletes",
                               "--find-query", "zzzqqxnobody"]
        app.launch()
        XCTAssertTrue(app.otherElements["search-no-results"].waitForExistence(timeout: 25)
                        || app.staticTexts["No athletes found"].waitForExistence(timeout: 5),
                      "A query matching nobody showed no empty state.")
    }

    // MARK: Media opening

    /// The alternate rectangle is a two-way in-post switch, never a lightbox: visual → photos puts
    /// the body in the rectangle, then body → visual puts the photos back there.
    @MainActor
    func testWorkoutMediaRectangleSwapsBothDirections() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--profile-tab", "--profile-open-strength"]
        app.launch()

        guard let photos = hittableButton("Workout photos", in: app, timeout: 25) else {
            XCTFail("A visual-cover lift did not put its attached photos in the alternate rectangle.")
            return
        }
        photos.tap()

        guard let body = hittableButton("Strength session visual", in: app, timeout: 5) else {
            XCTFail("Bringing photos forward did not move the body visual into the rectangle.")
            return
        }
        XCTAssertFalse(app.otherElements["workout-visual-full-screen"].exists,
                       "The cover switch incorrectly opened a separate viewer.")
        body.tap()
        XCTAssertNotNil(hittableButton("Workout photos", in: app, timeout: 5),
                      "Tapping the body visual did not restore it as the cover.")
    }

    /// Same contract for a real route: the author's photo-cover preference establishes the first
    /// frame, tapping Route map makes the explorable route + replay control the hero, and tapping
    /// the photo rectangle restores the carousel.
    @MainActor
    func testRouteAndPhotosSwapWhileReplayStaysWithTheRouteHero() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--seed-route-photo-cover",
                               "--profile-tab", "--profile-open-run"]
        app.launch()

        guard let route = hittableButton("Route map", in: app, timeout: 25) else {
            XCTFail("A photo-cover run did not put its route in the alternate rectangle.")
            return
        }
        route.tap()

        guard let photos = hittableButton("Workout photos", in: app, timeout: 5) else {
            XCTFail("Bringing the route forward did not move the photos into the rectangle.")
            return
        }
        XCTAssertTrue(app.buttons["routeReplayButton"].waitForExistence(timeout: 5),
                      "The route hero did not expose route replay.")
        XCTAssertFalse(app.otherElements["workout-visual-full-screen"].exists,
                       "The route switch incorrectly opened a separate viewer.")
        photos.tap()
        XCTAssertNotNil(hittableButton("Route map", in: app, timeout: 5),
                      "Tapping the photo rectangle did not restore the author's photo cover.")
    }

    /// Pin the same exchange inside the real Community vertical pager. This path has its own lazy
    /// page state and Mapbox lifecycle, so the profile viewer's matching test cannot protect it.
    @MainActor
    func testCommunityRouteRectangleSwapsBothDirections() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--seed-route-photo-cover",
                               "--profile-tab", "--profile-community", "--community-friends",
                               "--open-photo-route-post"]
        app.launch()

        guard let route = hittableButton("Route map", in: app, timeout: 35) else {
            XCTFail("The Community photo-cover post did not expose its route rectangle.")
            return
        }
        route.tap()

        guard let photos = hittableButton("Workout photos", in: app, timeout: 8) else {
            XCTFail("The Community route did not become hero or move the photos into the rectangle.")
            return
        }
        XCTAssertTrue(app.buttons["routeReplayButton"].waitForExistence(timeout: 8),
                      "Community route replay was not connected to the route hero.")
        photos.tap()
        XCTAssertNotNil(hittableButton("Route map", in: app, timeout: 8),
                        "The Community pager did not restore the author's photo cover.")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// A post with one media source has no fake switcher. The route itself remains interactive and
    /// replayable; there simply is not a second object to exchange with it.
    @MainActor
    func testPostWithoutPhotosHasNoHittableMediaRectangle() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--profile-tab", "--profile-open-run"]
        app.launch()

        XCTAssertTrue(app.buttons["routeReplayButton"].waitForExistence(timeout: 25),
                      "The no-photo route post did not reach its route hero.")
        XCTAssertFalse(app.buttons["Workout photo"].isHittable)
        XCTAssertFalse(app.buttons["Workout photos"].isHittable)
        XCTAssertFalse(app.buttons["Route map"].isHittable)
        XCTAssertFalse(app.buttons["Strength session visual"].isHittable)
    }

    /// Attached photos are a separate door into their own lightbox. This deliberately launches
    /// fresh instead of depending on the workout-visual test's presentation state.
    @MainActor
    func testAttachedPhotoOpensFullScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-open-strength"]
        app.launch()

        guard let edit = hittableButton("Edit activity", in: app, timeout: 25) else {
            XCTFail("The activity editor was unreachable.")
            return
        }
        edit.tap()

        let photo = app.buttons["Open photo 1 of 2"]
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, !photo.isHittable {
            app.swipeUp()
            usleep(250_000)
        }
        XCTAssertTrue(photo.isHittable, "The attached photo was not an interactive thumbnail.")
        photo.tap()

        XCTAssertTrue(app.otherElements["photo-lightbox"].waitForExistence(timeout: 8)
                        || app.buttons["Close photo"].waitForExistence(timeout: 2),
                      "Tapping the attached photo did not open the photo lightbox.")
        app.buttons["Close photo"].tap()
        XCTAssertTrue(app.navigationBars["Edit activity"].waitForExistence(timeout: 5),
                      "Closing the lightbox did not return to the activity editor.")
    }

    // MARK: Helpers

    /// A vertical LazyVStack realizes neighboring posts, so labels such as "Workout photos" can
    /// legitimately exist more than once. XCUITest's subscript demands one match and may tap an
    /// off-screen recycled page; selecting the currently hittable control mirrors a real finger.
    private func hittableButton(_ label: String, in app: XCUIApplication,
                                timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let query = app.buttons.matching(NSPredicate(format: "label == %@", label))
        while Date() < deadline {
            if let button = query.allElementsBoundByIndex.first(where: \.isHittable) {
                return button
            }
            usleep(100_000)
        }
        return nil
    }

    /// Maya's newest grid tile → the community pager, opened on that exact post. The tile label is
    /// "<name>, <title>, <stat line>, <when>"; the "when" drifts between launches, so match on the
    /// name prefix and take the first tile, which is ledger slot 0.
    private func openNewestTile(_ app: XCUIApplication) {
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Maya Rivera, '")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "No tiles on the visited athlete's grid.")
        tile.tap()
    }

    /// The pager realizes several pages at once, so more than one rail can carry a "Comments"
    /// button — an unqualified query is ambiguous, and a page still settling reports an 18pt-wide
    /// rail that fails the tap as "not hittable". Take the first HITTABLE one, and keep looking
    /// until the page has settled.
    private func openComments(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let bubble = app.buttons.matching(NSPredicate(format: "label == %@", "Comments"))
                .allElementsBoundByIndex.first(where: \.isHittable)
            if let bubble {
                bubble.tap()
                if app.buttons["Done"].waitForExistence(timeout: 8) { return }
            }
            usleep(400_000)
        }
        XCTFail("The pager's comment control never became usable.")
    }

    /// SwiftUI's `TextField(axis: .vertical)` can surface as a text VIEW rather than a text field
    /// depending on how it has grown, so accept either.
    private func commentField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["comment-field"]
        return field.exists ? field : app.textViews["comment-field"]
    }

    /// The thread header ("3 comments" / "1 comment"), or 0 when the thread is empty and the
    /// header isn't drawn at all.
    private func commentCount(_ app: XCUIApplication) -> Int {
        let header = app.staticTexts["comment-count"]
        guard header.waitForExistence(timeout: 5) else { return 0 }
        return Int(header.label.split(separator: " ").first.map(String.init) ?? "") ?? 0
    }
}
