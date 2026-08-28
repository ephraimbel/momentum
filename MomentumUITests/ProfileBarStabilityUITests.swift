import XCTest

/// The profile top bar must not move across the Profile ↔ Community flip (owner, 2026-08-27: "the
/// slider slightly moves up ... the settings button slightly moves up or gets smaller"). Both
/// faces now draw ONE `ProfileTopBar` at one inset, so the capsule and the gear are the same
/// views in the same frame on both sides. This pins that with real frames, not screenshots —
/// a 1pt drift fails it.
final class ProfileBarStabilityUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/b8839876-7419-4961-972d-88927a718cdc/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testSliderAndGearHoldTheirFramesAcrossTheFaceFlip() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--reset-social", "--ui-test-social"]
        app.launch()

        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "Settings missing on the profile face.")
        // "Profile" also names the TAB BAR item, and `firstMatch` can bind that one — tapping it
        // re-selects the tab and never flips the face. Bind the segment by position: the slider
        // sits in the top bar, the tab bar at the bottom.
        func topBarButton(_ label: String) -> XCUIElement {
            app.buttons.matching(identifier: label).allElementsBoundByIndex
                .first { $0.frame.midY < app.frame.midY } ?? app.buttons[label].firstMatch
        }
        XCTAssertTrue(app.buttons["Community"].firstMatch.waitForExistence(timeout: 5), "Slider missing on the profile face.")
        let profileSeg = topBarButton("Profile")
        let communitySeg = topBarButton("Community")

        let gearBefore = gear.frame
        let profileBefore = profileSeg.frame
        let communityBefore = communitySeg.frame
        dump(app, "bar_profile_face")

        communitySeg.tap()
        // The community face assembles a large feed; wait for something only IT renders.
        XCTAssertTrue(app.buttons["Find people"].waitForExistence(timeout: 30), "Community face did not open.")
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "Settings missing on the community face.")
        dump(app, "bar_community_face")

        // Exact equality, not "close": the complaint was a slight shift, so a slight shift fails.
        XCTAssertEqual(gear.frame, gearBefore,
                       "Settings moved across the flip: \(gearBefore) → \(gear.frame)")
        XCTAssertEqual(profileSeg.frame, profileBefore,
                       "Profile segment moved across the flip: \(profileBefore) → \(profileSeg.frame)")
        XCTAssertEqual(communitySeg.frame, communityBefore,
                       "Community segment moved across the flip: \(communityBefore) → \(communitySeg.frame)")

        // And back, for the round trip.
        topBarButton("Profile").tap()
        XCTAssertTrue(app.buttons["Edit profile"].waitForExistence(timeout: 15), "Profile face did not come back.")
        XCTAssertEqual(gear.frame, gearBefore, "Settings moved on the way back.")
        XCTAssertEqual(topBarButton("Community").frame, communityBefore, "Community segment moved on the way back.")
    }
}
