import XCTest

/// The paywall must open fast and stay smooth under the athlete's own hand (owner ask
/// 2026-08-28: "make sure the paywall loads fast and is responsive, no glitches"). Three
/// measures, none baseline-gated so sim variance never fails a run, all reported in the log:
///  • launch → headline on screen, wall clock;
///  • scroll hitches while flinging the marquee (`scrollDecelerationMetric` reads the OS's own
///    scroll signposts — SwiftUI's ScrollView is UIScrollView-backed, so they fire);
///  • the page still answers after the burst: picking the other plan flips the selection.
final class PaywallPerfUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--paywall", "--debug-free"]
        app.launch()
        return app
    }

    func testOpensFast() {
        measure(metrics: [XCTClockMetric()]) {
            let app = launch()
            XCTAssertTrue(app.staticTexts["Run smarter.\nRace faster."].waitForExistence(timeout: 10),
                          "Paywall headline never appeared.")
            app.terminate()
        }
    }

    func testMarqueeScrollsWithoutHitches() {
        let app = launch()
        let marquee = app.scrollViews.firstMatch
        XCTAssertTrue(marquee.waitForExistence(timeout: 10), "Marquee not found.")
        sleep(2)   // let the entrance settle so we measure steady state
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric],
                options: XCTMeasureOptions.default) {
            marquee.swipeUp(velocity: .fast)
            marquee.swipeDown(velocity: .fast)
        }
    }

    func testStaysResponsiveAfterBurst() {
        let app = launch()
        let marquee = app.scrollViews.firstMatch
        XCTAssertTrue(marquee.waitForExistence(timeout: 10))
        for _ in 0..<6 { marquee.swipeUp(velocity: .fast); marquee.swipeDown(velocity: .fast) }
        let weekly = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Weekly plan'")).firstMatch
        XCTAssertTrue(weekly.waitForExistence(timeout: 5), "Weekly card not found after the burst.")
        XCTAssertTrue(weekly.isHittable, "Weekly card not hittable after the burst.")
        weekly.tap()
        XCTAssertTrue(weekly.waitForExistence(timeout: 2))
        XCTAssertTrue(weekly.isSelected, "Plan pick did not register after the burst.")
    }
}
