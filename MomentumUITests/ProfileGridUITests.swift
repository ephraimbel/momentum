import XCTest

/// Verifies the redesigned Profile: the TikTok-style workout grid rides high, the "Highlights" tab
/// carries lifetime/how-you-train/consistency, and tapping a tile opens the immersive pager. Also dumps
/// PNGs to /tmp for visual inspection.
final class ProfileGridUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
    }

    func testGridHighlightsAndImmersivePager() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        // No blind center-tap here: on the redesigned profile the screen center lands on a grid
        // tile, and the tap opened the immersive pager over everything ("Highlights" unhittable).

        // Profile is the tab root — the grid tab bar is present.
        let gridTab = app.buttons["Grid"]
        XCTAssertTrue(gridTab.waitForExistence(timeout: 20), "Profile grid didn't load.")
        let highlightsTab = app.buttons["Highlights"]
        XCTAssertTrue(highlightsTab.exists, "Highlights tab missing.")

        // Highlights tab carries the moved lifetime/how-you-train/consistency sections.
        highlightsTab.tap()
        // Section headers are uppercased editorial rules (2026-07-22 design pass).
        XCTAssertTrue(app.staticTexts["LIFETIME"].waitForExistence(timeout: 5), "Lifetime section not in Highlights.")
        XCTAssertTrue(app.staticTexts["HOW YOU TRAIN"].exists, "How-you-train not in Highlights.")
        XCTAssertTrue(app.staticTexts["CONSISTENCY"].exists, "Consistency not in Highlights.")
        dump(app, "verify_highlights")

        // Back to the grid; tap a run tile (label carries the distance) → immersive pager.
        gridTab.tap()
        let runTile = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'mi'")).firstMatch
        XCTAssertTrue(runTile.waitForExistence(timeout: 5), "No run tiles in the grid.")
        // The tile label is "Run, 4.45 mi" — grab the distance so we can confirm the pager opens on it.
        let distance = runTile.label.components(separatedBy: ", ").last ?? ""
        runTile.tap()

        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Immersive pager didn't open.")
        // The pager must open ON the tapped workout, not at the top of the list.
        XCTAssertTrue(app.staticTexts[distance].waitForExistence(timeout: 3),
                      "Pager didn't open on the tapped workout (\(distance)).")
        dump(app, "verify_pager")

        // Swipe to the next workout, then close.
        app.swipeUp()
        dump(app, "verify_pager_next")
        app.swipeUp()
        dump(app, "verify_pager_next2")
        close.tap()
        XCTAssertTrue(gridTab.waitForExistence(timeout: 5), "Didn't return to the grid after closing.")
    }
}
