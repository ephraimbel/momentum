import XCTest

/// Verifies the activity picker offers the newly-added water disciplines (PRD §4.10 "more
/// disciplines") and that selecting one updates the chip — exercising the timed-capture routing.
final class SportPickerUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testWaterSportsAppearAndSelect() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--ui-test-route"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "OK", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        app.tap()

        // Open the activity picker from the Today sport chip. Its tap target goes through
        // `mapSafeTap`, which REPLACES the children's accessibility with one label of its own
        // ("Change activity — Run selected"), so the bare "Run" this used to ask for never existed
        // as an element. Match the prefix so the suite survives the athlete's selected sport
        // changing, which is the only part of that label that moves.
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Change activity'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "Sport chip not found.")
        chip.tap()

        XCTAssertTrue(app.navigationBars["Choose Activity"].waitForExistence(timeout: 5),
                      "Sport picker didn't open.")

        // Search to reach the new disciplines deterministically (no scrolling guesswork).
        let search = app.textFields["Search activities"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Swim")

        let swim = app.buttons["Swim"]
        XCTAssertTrue(swim.waitForExistence(timeout: 5), "Swim not offered in the picker.")
        swim.tap()

        // Selecting it dismisses the picker and updates the chip to the new sport. Assert on the
        // CHIP's own label, not a bare "Swim": that only ever matched the picker row that just went
        // away, so this could never have observed the thing it names.
        let chosen = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Change activity'")).firstMatch
        XCTAssertTrue(chosen.waitForExistence(timeout: 5), "Activity chip missing after selection.")
        XCTAssertTrue(chosen.label.contains("Swim"),
                      "Selecting Swim didn't update the activity chip (chip reads \"\(chosen.label)\").")
    }

    /// "Your activities" DEDUPES against the category sections (owner call 2026-07-30): a sport
    /// shown in the shortcut section must not appear again below — Run in both "Your activities"
    /// and "Foot Sports" read as a doubled list. Also walks the list to the last sport so every
    /// category still renders. Dumps PNGs of each scroll state for visual inspection.
    func testYourActivitiesNeverDoubledInCategories() {
        let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/ca341ef2-320d-43bb-88d9-1deb69360c06/scratchpad"
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--sport-picker"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Choose Activity"].waitForExistence(timeout: 15),
                      "Sport picker didn't open from --sport-picker.")
        XCTAssertTrue(app.staticTexts["YOUR ACTIVITIES"].exists, "Shortcut section missing.")
        // The demo athlete's most-logged sport is Run — it sits in "Your activities" and must
        // appear EXACTLY once on this screen. (Both sections render up front; a duplicate below
        // would exist in the hierarchy even before scrolling.)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Run'")).count, 1,
                       "A sport in \"Your activities\" is doubled in its category section.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_picker_1.png"))

        // Walk to the very last row — proves every category still renders and scrolls.
        // (`WorkoutType.other`'s display title is "Workout" — the OTHER header, Workout row.)
        let last = app.buttons["Workout"]
        var swipes = 0
        while !(last.exists && last.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_picker_\(swipes + 1).png"))
        }
        XCTAssertTrue(last.exists && last.isHittable, "Couldn't scroll to the last sport row.")
        for header in ["GYM & STRENGTH", "SPORTS", "MIND & BODY", "OTHER"] {
            XCTAssertTrue(app.staticTexts[header].exists, "\(header) section missing from the list.")
        }
    }
}
