import XCTest

/// The record book (Progress → Trends, in the athlete story below the panel): backfill populates
/// persisted PRs from seeded history and the card lists lifetime bests with dates. The former You
/// segment merged into Trends (2026-07), so the test deep-scrolls to the card instead of tapping a
/// segment. Dumps a PNG for visual inspection.
final class RecordsCardUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testRecordBookShowsBests() {
        let app = XCUIApplication()
        // Record Book lives in the Pro analytics cluster; the regression verifies its populated
        // state, not the free-tier teaser that deliberately replaces that whole cluster.
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-pro",
                               "--progress-tab", "--progress-scroll-records"]
        app.launch()

        let title = app.staticTexts["RECORD BOOK"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Record book card missing.")
        // Rows intentionally collapse their children into one VoiceOver sentence, so assert that
        // accessible contract instead of looking for child StaticTexts that are correctly hidden.
        let allElements = app.descendants(matching: .any)
        let fastest5K = allElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Fastest 5K:")).firstMatch
        let longestRun = allElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Longest run:")).firstMatch
        XCTAssertTrue(fastest5K.exists, "Fastest 5K row missing.")
        XCTAssertTrue(longestRun.exists, "Longest run row missing.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_recordbook.png"))
    }
}
