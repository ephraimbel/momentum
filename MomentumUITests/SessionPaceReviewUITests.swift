import XCTest

/// Verifies the session pace review + HR analysis on a guided run's detail (R4): the seeded recent
/// run carries RepResults and an HR trace, so the detail must show the PACE REVIEW verdict card and
/// the heart-rate chart. Dumps a PNG for visual inspection.
final class SessionPaceReviewUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testGuidedRunDetailShowsPaceReviewAndHRChart() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-run-detail"]
        app.launch()

        let title = app.staticTexts["PACE REVIEW"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "Pace review card not rendered on run detail.")
        // The seeded 6×400 (one slow rep, mean within band) reads as On point.
        XCTAssertTrue(app.staticTexts["ON POINT"].exists, "Verdict chip missing.")

        app.swipeUp()
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_pacereview.png"))

        // The HR analysis renders from the locally seeded series.
        let hr = app.staticTexts["HEART RATE"]
        let deadline = Date().addingTimeInterval(10)
        while !hr.exists && Date() < deadline { app.swipeUp(); usleep(300_000) }
        XCTAssertTrue(hr.exists, "Heart-rate chart missing from run detail.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_hrchart.png"))
    }
}
