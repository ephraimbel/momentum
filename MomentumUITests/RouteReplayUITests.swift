import XCTest

/// The premium route replay must open from the real post-run surface, remain controllable, and
/// return to the exact activity. A second path pins the free-tier upgrade moment.
@MainActor
final class RouteReplayUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testProAthleteCanReplayAndReturnToPostRun() {
        let app = launch(pro: true)
        let replay = app.buttons["routeReplayButton"]
        XCTAssertTrue(replay.waitForExistence(timeout: 40))
        replay.tap()

        let screen = app.descendants(matching: .any)["routeReplayScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 20), "Replay should open over the saved run.")
        XCTAssertTrue(app.sliders["Route replay position"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Pause route replay"].waitForExistence(timeout: 8),
                      "A Pro replay should auto-play when Reduce Motion is off.")
        XCTAssertTrue(app.buttons["Show route overview"].exists)
        XCTAssertTrue(app.buttons["routeReplay3DButton"].exists)
        XCTAssertTrue(app.buttons["routeReplayShareButton"].exists)

        app.buttons["Pause route replay"].tap()
        XCTAssertTrue(app.buttons["Play route replay"].waitForExistence(timeout: 5))
        app.buttons["Close route replay"].tap()
        XCTAssertTrue(replay.waitForExistence(timeout: 12),
                      "Closing replay must return to the same post-run activity.")
    }

    func testFreeAthleteSeesProOfferWithoutLeavingPostRun() {
        let app = launch(pro: false)
        let replay = app.buttons["routeReplayButton"]
        XCTAssertTrue(replay.waitForExistence(timeout: 40))
        replay.tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 12), "Locked replay should open the Pro offer.")
        close.tap()
        XCTAssertTrue(replay.waitForExistence(timeout: 12),
                      "Closing the offer must return to the saved run.")
    }

    func testReplayCanSwitchBetweenFollowAndOverviewWithoutRestarting() {
        let app = launch(pro: true)
        let replay = app.buttons["routeReplayButton"]
        XCTAssertTrue(replay.waitForExistence(timeout: 40))
        replay.tap()

        let screen = app.descendants(matching: .any)["routeReplayScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Close route replay"].waitForExistence(timeout: 8))

        // Freeze playback while stressing the camera-mode control. Otherwise the short demo
        // route can legitimately finish during XCTest's relatively slow accessibility taps,
        // changing the finished-state action to "Follow athlete" midway through this loop.
        let pause = app.buttons["Pause route replay"]
        XCTAssertTrue(pause.waitForExistence(timeout: 8))
        pause.tap()
        XCTAssertTrue(app.buttons["Play route replay"].waitForExistence(timeout: 5))

        // Repeated transitions exercise the former race between the 30 Hz follow camera and the
        // animated whole-route camera. The replay must remain foregrounded throughout.
        for _ in 0..<3 {
            let overview = app.buttons["Show route overview"]
            XCTAssertTrue(overview.waitForExistence(timeout: 5))
            overview.tap()
            let follow = app.buttons["Follow athlete"]
            XCTAssertTrue(follow.waitForExistence(timeout: 5))
            XCTAssertTrue(screen.exists)
            follow.tap()
            XCTAssertTrue(overview.waitForExistence(timeout: 5))
            XCTAssertTrue(screen.exists)
        }

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.sliders["Route replay position"].exists)
    }

    func testCompletedReplayRestartsInFollowModeAndCanBePresentedAgain() {
        let app = launch(pro: true)
        let entry = app.buttons["routeReplayButton"]
        XCTAssertTrue(entry.waitForExistence(timeout: 40))
        entry.tap()

        XCTAssertTrue(app.buttons["Close route replay"].waitForExistence(timeout: 20))
        // The post-run entry remains mounted behind SwiftUI's full-screen cover. Match the
        // in-replay restart control, which intentionally has no `routeReplayButton` identifier,
        // so this wait cannot succeed against the hidden entry before playback finishes.
        let restart = app.buttons
            .matching(NSPredicate(format: "label == 'Replay route' AND identifier != 'routeReplayButton'"))
            .firstMatch
        XCTAssertTrue(restart.waitForExistence(timeout: 40),
                      "A finished replay should settle into a restartable state.")
        XCTAssertTrue(app.buttons["Follow athlete"].waitForExistence(timeout: 5),
                      "Completion should truthfully report that the camera is in overview.")

        restart.tap()
        XCTAssertTrue(app.buttons["Pause route replay"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Show route overview"].waitForExistence(timeout: 5),
                      "Restarting should begin in follow mode, not retain the finished overview.")
        XCTAssertEqual(app.state, .runningForeground)

        app.buttons["Close route replay"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        entry.tap()
        XCTAssertTrue(app.buttons["Close route replay"].waitForExistence(timeout: 20),
                      "Replay must be safe to present again after dismissal.")
        XCTAssertTrue(app.sliders["Route replay position"].exists)
    }

    func testCinematicCameraCanSwitchBetween3DAndFlatWithoutLeavingReplay() {
        let app = launch(pro: true)
        _ = openProReplay(in: app)

        // Hold the timeline still while asserting camera state. At 30 Hz, XCTest can otherwise
        // retain an accessibility snapshot from the frame immediately before its synthetic tap.
        let pause = app.buttons["Pause route replay"]
        XCTAssertTrue(pause.waitForExistence(timeout: 25),
                      "Camera controls should activate after Mapbox produces its first usable frame.")
        pause.tap()
        XCTAssertTrue(app.buttons["Play route replay"].waitForExistence(timeout: 5))

        let flatten = app.buttons["Use flat replay camera"]
        XCTAssertTrue(flatten.waitForExistence(timeout: 8))
        // Accessibility is ready before Mapbox's network-backed tiles necessarily finish their
        // first composite. Give the visual-regression attachment one short rendering window.
        Thread.sleep(forTimeInterval: 6)
        let visual = XCTAttachment(screenshot: app.screenshot())
        visual.name = "route-replay-cinematic"
        visual.lifetime = .keepAlways
        add(visual)
        flatten.tap()
        let make3D = app.buttons["Use cinematic 3D replay camera"]
        XCTAssertTrue(make3D.waitForExistence(timeout: 8))
        XCTAssertTrue(app.sliders["Route replay position"].exists)
        make3D.tap()
        XCTAssertTrue(flatten.waitForExistence(timeout: 8))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testClosingDuringPrivateVideoPreparationCancelsCleanly() {
        let app = launch(pro: true, extraArguments: ["--route-replay-export-test-delay",
                                                     "--route-replay-start-paused"])
        let entry = app.buttons["routeReplayButton"]
        let close = openProReplay(in: app)

        let share = app.buttons["routeReplayShareButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        share.tap()
        // The progress card is intentionally one combined accessibility element, whose concrete
        // XCUI element type varies by iOS. The share control's state label is the stable contract.
        XCTAssertTrue(app.buttons["Creating private replay video"].waitForExistence(timeout: 5))
        close.tap()

        XCTAssertTrue(entry.waitForExistence(timeout: 12),
                      "Cancelling an export must return to the exact saved activity.")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testCommunityReplayHasAPaintedFirstFrameBeforeMapboxIsReady() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-pro",
                               "--profile-tab", "--profile-community",
                               "--open-first-route-post", "--route-replay-map-ready-delay"]
        app.launch()

        let entry = app.buttons["routeReplayButton"]
        // A routed post may intentionally open on the author's selected photo cover. Bring its
        // route alternate forward before asserting replay, instead of coupling this regression to
        // seeded feed order or cover choice.
        if !entry.waitForExistence(timeout: 8) {
            let routeThumb = app.buttons["Route map"]
            XCTAssertTrue(routeThumb.waitForExistence(timeout: 25),
                          "The debug route post should expose either its route or route thumbnail.")
            routeThumb.tap()
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        entry.tap()

        let screen = app.descendants(matching: .any)["routeReplayScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 20),
                      "Community should present only after its shared route payload is ready.")
        XCTAssertTrue(app.otherElements["routeReplayLoadingBackdrop"].waitForExistence(timeout: 6),
                      "The route placeholder must paint while Mapbox prepares its first frame.")
        XCTAssertTrue(app.buttons["Close route replay"].exists,
                      "Replay chrome should never wait behind a blank loading page.")
        XCTAssertFalse(app.activityIndicators["Preparing route replay"].exists,
                       "Community must prepare on the post instead of showing a blank loading cover.")

        // Autoplay is intentionally held at zero until Mapbox has a usable style and camera.
        XCTAssertTrue(app.buttons["Pause route replay"].waitForExistence(timeout: 25))
        app.buttons["Close route replay"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testCommunityRouteSurfacesStayPaintedAcrossVerticalPaging() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-pro",
                               "--profile-tab", "--profile-community", "--community-friends",
                               "--reset-social", "--ui-test-social", "--open-post", "1"]
        app.launch()

        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 45))
        var routedPosts = 0
        for page in 0..<10 {
            let replay = app.buttons["routeReplayButton"]
            if replay.exists && replay.isHittable {
                XCTAssertTrue(waitForPaintedCommunityRoute(in: app, timeout: 5),
                              "Community route post \(page) had no painted route surface.")
                routedPosts += 1
            }
            XCTAssertEqual(app.state, .runningForeground,
                           "Paging to Community post \(page) must not restart the app.")
            if page < 9 { app.swipeUp() }
        }
        XCTAssertGreaterThanOrEqual(routedPosts, 4,
                                    "The paging regression did not exercise enough route posts.")

    }

    /// Mapbox and SwiftUI mount two UIKit hierarchies during the post-run hero's first frame.
    /// A simulator can acknowledge a synthetic tap against the outgoing accessibility snapshot
    /// without delivering it. Real touches do not exhibit this, but one verified retry keeps the
    /// regression suite deterministic while still failing if replay cannot actually present.
    private func openProReplay(in app: XCUIApplication) -> XCUIElement {
        let entry = app.buttons["routeReplayButton"]
        XCTAssertTrue(entry.waitForExistence(timeout: 40))
        let close = app.buttons["Close route replay"]

        entry.tap()
        if !close.waitForExistence(timeout: 8) {
            app.activate()
            XCTAssertTrue(entry.waitForExistence(timeout: 8))
            entry.tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 20),
                      "Replay should present from the post-run route hero.")
        return close
    }

    private func launch(pro: Bool, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", pro ? "--debug-pro" : "--debug-free",
                               "--save-screen"] + extraArguments
        app.launch()
        return app
    }

    private func waitForPaintedCommunityRoute(in app: XCUIApplication,
                                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let surfaces = app.descendants(matching: .any)
                .matching(identifier: "communityRouteSurface")
                .allElementsBoundByIndex
            if surfaces.contains(where: { $0.exists && $0.isHittable && $0.frame.height > 300 }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }
}
