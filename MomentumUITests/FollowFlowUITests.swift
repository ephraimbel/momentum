import XCTest

/// The follow graph, end to end through the real UI (owner ask 2026-07-30: "if I press follow, I
/// actually follow them, and it shows on my account"). Two phases so the loop is covered whole:
///
/// 1. Follow from an athlete's profile → the pill flips → the athlete's own follower count rises.
/// 2. **Relaunch** → the athlete's own profile shows `1 Following` (so the follow survived a cold
///    start), the Following list actually lists them, and unfollowing from that list takes.
///
/// The relaunch also sidesteps the ambiguity of two "Profile" buttons on one screen (the tab bar
/// item and the Profile|Community slider) — phase 2 lands on the profile face directly.
/// `--reset-social` in phase 1 only: phase 2 must inherit the follow, not wipe it.
final class FollowFlowUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testFollowRaisesOwnCountAndListsTheAthlete() {
        let app = XCUIApplication()

        // MARK: Phase 1 — follow from Maya's profile
        app.launchArguments = ["--seed-demo", "--reset-social", "--profile-tab",
                               "--profile-community", "--athlete-profile", "mayaruns"]
        app.launch()

        let follow = app.buttons["Follow Maya Rivera"]
        XCTAssertTrue(follow.waitForExistence(timeout: 25), "Athlete profile didn't open on the Follow state.")
        // Her graph-derived follower count includes the viewer's own follow, so it must tick up
        // by one. (The line is a BUTTON now — it pushes her Followers/Following lists; 98/250 are
        // Maya's emergent CommunityGraph counts, pinned by SocialFollowTests.)
        XCTAssertTrue(app.buttons["98 followers, 250 following"].exists,
                      "Unexpected pre-follow counts on the athlete profile.")
        follow.tap()

        // The tap took: the pill flips. (The profile pill states the state then the action for
        // VoiceOver; the list's terser "Unfollow X" is asserted in phase 2.)
        XCTAssertTrue(app.buttons["Following Maya Rivera. Tap to unfollow."].waitForExistence(timeout: 5),
                      "Follow tap didn't register in the store.")
        XCTAssertTrue(app.buttons["99 followers, 250 following"].waitForExistence(timeout: 5),
                      "Athlete's follower count didn't include the viewer's follow.")

        // And BACK: unfollowing takes the follower away again (2026-08-15 — the other half of
        // "a follow changes the number for each of them"), then re-follow for phase 2.
        app.buttons["Following Maya Rivera. Tap to unfollow."].tap()
        XCTAssertTrue(app.buttons["98 followers, 250 following"].waitForExistence(timeout: 5),
                      "Unfollow didn't drop the athlete's follower count back.")
        app.buttons["Follow Maya Rivera"].tap()
        XCTAssertTrue(app.buttons["99 followers, 250 following"].waitForExistence(timeout: 5),
                      "Re-follow didn't restore the +1.")

        // MARK: Phase 2 — the follow shows on the athlete's OWN account, after a cold start
        app.terminate()
        app.launchArguments = ["--seed-demo", "--profile-tab"]
        app.launch()

        // The count is REAL: followers stay honestly 0 (no backend serves a list), following is 1.
        let socialLine = app.buttons["0 followers, 1 following"]
        XCTAssertTrue(socialLine.waitForExistence(timeout: 25),
                      "Own profile's Following count didn't survive the relaunch.")

        // The list agrees with the count — the case that used to show "Nobody yet" over a 1.
        socialLine.tap()
        let row = app.buttons["View Maya Rivera's profile"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Followed athlete missing from the Following list.")

        // Unfollowing from the list takes, and the row's pill flips back.
        app.buttons["Unfollow Maya Rivera"].tap()
        XCTAssertTrue(app.buttons["Follow Maya Rivera"].waitForExistence(timeout: 5),
                      "Unfollow from the list didn't take.")
    }
}
