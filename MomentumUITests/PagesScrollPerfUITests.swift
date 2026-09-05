import XCTest

/// Every tab must stay smooth after the glass pass (owner ask 2026-08-27: "make sure the app is
/// still fast and responsive"). Each test opens a page, records the wall-clock cost of a scroll
/// burst, including the system's scrolling/deceleration hitch metrics, then proves the page still
/// answers. Simulator results are diagnostic; establish regression baselines on a physical device.
final class PagesScrollPerfUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func burst(_ app: XCUIApplication, args: [String], settle: TimeInterval = 4) {
        app.launchArguments = ["--seed-demo"] + args
        app.launch()
        sleep(UInt32(settle))
        ScrollTestSupport.dismissRecoveryIfPresent(app)
        guard let surface = ScrollTestSupport.pageSurface(in: app) else { return }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
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

/// Recording tests intentionally exercise recovery and may leave a recoverable sample workout.
/// Keep it, but close its prompt before measuring. Never accidentally benchmark the alert's
/// small text scroll view (which is also returned by `app.scrollViews.firstMatch`).
enum ScrollTestSupport {
    static func dismissRecoveryIfPresent(_ app: XCUIApplication, timeout: TimeInterval = 0) {
        let recovery = app.alerts["Unfinished run found"]
        if recovery.waitForExistence(timeout: timeout) {
            recovery.buttons["Cancel"].tap()
            XCTAssertTrue(recovery.waitForNonExistence(timeout: 5), "Recovery prompt did not close.")
        }
    }

    static func pageSurface(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement? {
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10),
                      "Expected page scroll view never appeared.", file: file, line: line)
        guard let surface = app.scrollViews.allElementsBoundByIndex
            .filter({ $0.isHittable })
            .max(by: { $0.frame.height < $1.frame.height }),
              surface.frame.height > app.frame.height * 0.5 else {
            XCTFail("No full-page scroll surface is reachable; do not measure a nested control or alert.",
                    file: file, line: line)
            return nil
        }
        return surface
    }
}
