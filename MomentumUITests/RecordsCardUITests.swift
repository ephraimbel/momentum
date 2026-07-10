import XCTest

/// The record book (Progress → You): backfill populates persisted PRs from seeded history and the
/// card lists lifetime bests with dates. Dumps a PNG for visual inspection.
final class RecordsCardUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testRecordBookShowsBests() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--progress-tab"]
        app.launch()
        app.tap()

        let you = app.buttons["You"]
        XCTAssertTrue(you.waitForExistence(timeout: 20), "'You' segment not found.")
        you.tap()

        let title = app.staticTexts["RECORD BOOK"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Record book card missing.")
        XCTAssertTrue(app.staticTexts["Fastest 5K"].exists, "Fastest 5K row missing.")
        XCTAssertTrue(app.staticTexts["Longest run"].exists, "Longest run row missing.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_recordbook.png"))
    }
}
