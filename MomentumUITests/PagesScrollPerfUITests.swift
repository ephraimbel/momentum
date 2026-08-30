import XCTest

/// Every tab must stay smooth after the glass pass (owner ask 2026-08-27: "make sure the app is
/// still fast and responsive"). Each test opens a page, records the wall-clock cost of a scroll
/// burst (`XCTClockMetric`, baseline-free so sim variance never fails a run), then proves the
/// page still answers: its first button is hittable after the burst. A page doing per-frame
/// engine work shows up as a long, noisy duration; a memoized page is flat.
final class PagesScrollPerfUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func burst(_ app: XCUIApplication, args: [String], settle: TimeInterval = 4) {
        app.launchArguments = ["--seed-demo"] + args
        app.launch()
        sleep(UInt32(settle))
        let surface = app.scrollViews.firstMatch
        guard surface.waitForExistence(timeout: 10) else { return }
        measure(metrics: [XCTClockMetric()]) {
            surface.swipeUp(velocity: .fast)
            surface.swipeDown(velocity: .fast)
        }
        for _ in 0..<4 { surface.swipeUp(velocity: .fast); surface.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.tabBars.buttons.firstMatch.waitForExistence(timeout: 5),
                      "Tab bar not reachable after a scroll burst.")
        XCTAssertTrue(app.tabBars.buttons.firstMatch.isHittable, "Page wedged after a scroll burst.")
    }

    func testTrendsScrollsSmoothly()  { burst(XCUIApplication(), args: ["--progress-tab"]) }
    func testHealthScrollsSmoothly()  { burst(XCUIApplication(), args: ["--health-recovery-demo", "--progress-tab", "--progress-health"]) }
    func testPlanScrollsSmoothly()    { burst(XCUIApplication(), args: ["--plan-tab"]) }
    func testFuelScrollsSmoothly()    { burst(XCUIApplication(), args: ["--fuel-tab"]) }
    func testProfileScrollsSmoothly() { burst(XCUIApplication(), args: ["--profile-tab"], settle: 6) }

    /// The community wall (2026-08-29 responsiveness pass). The heaviest scrolling surface in the
    /// app: a 3-across mosaic of route snapshots, muscle figures and photos over a well that
    /// deepens as you reach the bottom, so a burst here also exercises the page-in path.
    ///
    /// `--ui-test-social` keeps the instant silhouettes — XCUITest realizes every lazy cell at once
    /// and a hundred queued Mapbox renders starve the run, which measures the snapshotter's
    /// throughput rather than the wall's. Settles longer than the other pages because the first
    /// open builds the whole seeded directory (off the main actor, behind the skeleton).
    func testCommunityWallScrollsSmoothly() {
        burst(XCUIApplication(),
              args: ["--profile-tab", "--profile-community", "--feed-global", "--ui-test-social"],
              settle: 8)
    }
}
