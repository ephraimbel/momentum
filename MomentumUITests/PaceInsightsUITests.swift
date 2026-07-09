import XCTest

/// Verifies the Pace Insights coach review (R4): a seeded guided run's detail shows the card with a
/// verdict chip and the per-rep achieved-vs-target table. Dumps a PNG for visual inspection.
final class PaceInsightsUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testGuidedRunDetailShowsPaceReview() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--progress-tab"]
        app.launch()
        app.tap()

        let history = app.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 20), "History segment not found.")
        history.tap()

        // The most recent seeded run carries step results (variant 0 → On point).
        let runCard = app.buttons["Run"].firstMatch
        XCTAssertTrue(runCard.waitForExistence(timeout: 10), "No run cards in history.")
        runCard.tap()

        let title = app.staticTexts["PACE INSIGHTS"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Pace Insights card not rendered.")
        // Bring the card fully into view for the dump.
        app.swipeUp()
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_paceinsights.png"))

        XCTAssertTrue(app.staticTexts["ON POINT"].exists, "Verdict chip missing.")
        XCTAssertTrue(app.staticTexts["Rep 1/5"].exists, "Per-rep table missing.")
    }
}
