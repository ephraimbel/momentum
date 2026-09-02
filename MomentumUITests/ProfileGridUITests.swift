import XCTest

/// Verifies the redesigned Profile: the TikTok-style workout grid rides high, the "Highlights" tab
/// carries lifetime/how-you-train/consistency, and tapping a tile opens the immersive pager. Also dumps
/// PNGs to /tmp for visual inspection.
final class ProfileGridUITests: XCTestCase {

    private var dumpDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("momentum-profile-grid-audit", isDirectory: true)
    }

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
        try? png.write(to: dumpDir.appendingPathComponent("\(name).png"))
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
        dump(app, "verify_grid")

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
        let distance = runTile.label.components(separatedBy: ", ")
            .first(where: { $0.range(of: #"^\d+(?:\.\d+)?\s+(?:mi|km)$"#,
                                     options: .regularExpression) != nil }) ?? ""
        XCTAssertFalse(distance.isEmpty, "Couldn't read a distance from '\(runTile.label)'.")
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
        // Re-resolve Close AFTER the swipes: the pager renders a Close per page, so `firstMatch`
        // can bind one that has scrolled off the top (seen at y = -804, "not hittable"). Tap
        // whichever one is actually on screen.
        let onScreenClose = app.buttons.matching(NSPredicate(format: "label == %@", "Close"))
            .allElementsBoundByIndex.first(where: \.isHittable) ?? close
        onScreenClose.tap()
        XCTAssertTrue(gridTab.waitForExistence(timeout: 5), "Didn't return to the grid after closing.")
    }

    /// The media counter pill sits BELOW the top-right control column — never under the Edit
    /// pencil. Owner report 2026-08-27: "1/3" rendered directly beneath the pencil on every
    /// multi-photo post, because the pill's offset was a hard-coded one-button height from before
    /// Edit joined the column. The seeded strength post carries two photos; its saved muscle-map
    /// cover opens first, so the test uses the same alternate-media swap an athlete does before
    /// judging the photo counter beside the share + edit column.
    func testMediaCounterClearsTheControlColumn() {
        let app = XCUIApplication()
        // The assertion depends on the canonical seeded strength post carrying two photos. A
        // pre-existing demo profile makes --seed-demo a no-op, so reset the shared UI-test store.
        app.launchArguments = ["--reset-store", "--seed-demo", "--profile-tab", "--profile-open-strength"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()

        // The pager renders chrome per page and neighbours may be realized off-screen — judge
        // only the elements actually on screen.
        let screen = app.frame
        func onScreen(_ q: XCUIElementQuery) -> XCUIElement? {
            q.allElementsBoundByIndex.first { screen.contains($0.frame) && $0.frame.height > 0 }
        }
        XCTAssertTrue(app.buttons["Edit activity"].firstMatch.waitForExistence(timeout: 8),
                      "Immersive pager didn't open on the strength post.")
        let photoThumb = app.buttons["Workout photos"]
        XCTAssertTrue(photoThumb.waitForExistence(timeout: 5),
                      "Seeded photos missing from the strength post's alternate-media card.")
        photoThumb.tap()
        let counterQuery = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Media 1 of'"))
        XCTAssertTrue(counterQuery.firstMatch.waitForExistence(timeout: 5),
                      "No media counter — the seeded strength post should carry photos.")
        guard let edit = onScreen(app.buttons.matching(identifier: "Edit activity")),
              let pill = onScreen(counterQuery) else {
            return XCTFail("Edit control or media counter not on screen.")
        }
        dump(app, "verify_pager_counter")
        XCTAssertFalse(edit.frame.intersects(pill.frame),
                       "Edit pencil overlaps the media counter: \(edit.frame) vs \(pill.frame)")
        XCTAssertGreaterThanOrEqual(pill.frame.minY, edit.frame.maxY,
                                    "Counter pill must sit below the whole control column.")
    }
}
