import XCTest

/// Pins the strength summary's Strava-shaped page (2026-08-13): the muscle-map identity card
/// directly under the hero, the splits-grammar exercise rows, and the tap-to-expand set detail.
final class StrengthSummaryUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testStrengthSaveShowsIdentityAndExpandsExercise() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--strength-save"]
        app.launch()

        // The hero (volume + stat row) leads the page.
        XCTAssertTrue(app.staticTexts["SETS"].waitForExistence(timeout: 15),
                      "Strength save screen didn't open on the hero.")

        // The splits-grammar exercise rows live below — swipe until the section header shows.
        // The photo section sits on the way down (2026-08-14: strength save can now attach
        // photos — it was the one save screen that couldn't), so assert it as we pass.
        let header = app.staticTexts["EXERCISES"]
        // The seeded lift already carries demo photos, so the section shows the manage strip
        // ("Add photo" tile) rather than the empty-state "Add photos" button — accept either.
        let addEmpty = app.staticTexts["Add photos"], addTile = app.buttons["Add photo"]
        var sawPhotos = addEmpty.exists || addTile.exists
        let deadline = Date().addingTimeInterval(10)
        while !header.exists, Date() < deadline {
            app.swipeUp(); usleep(300_000)
            sawPhotos = sawPhotos || addEmpty.exists || addTile.exists
        }
        XCTAssertTrue(sawPhotos, "Photo section missing from the strength save page.")
        XCTAssertTrue(header.exists, "Exercise breakdown missing from strength summary.")

        // Tap the first exercise ROW BUTTON → its set-by-set story opens ("Set 1, …" rows exist
        // only when expanded). Query buttons: a bare CONTAINS-'Barbell' descendant match lands on
        // the PR badge ("Barbell Back Squat · e1RM PR…") first, whose tap is a no-op.
        let row = app.buttons
            .matching(NSPredicate(format: "label CONTAINS 'Barbell'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "No exercise row found.")
        let set1 = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Set 1'")).firstMatch
        for _ in 0..<3 where !set1.exists {
            row.tap()
            _ = set1.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(set1.exists, "Tapping an exercise row never revealed its sets.")
    }
}
