import XCTest

/// The photo lane on the Fuel page (2026-09-07). The simulator has no camera and the library
/// picker runs out of process, so the client path is driven by `--fuel-photo-demo` (a drawn
/// plate through the real `addPhoto` → `logPhoto` → estimate → row chain) beside two seeded
/// photo meals: one resolved with items, one the server refused as not food.
final class FuelPhotoLaneUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPhotoRowsAndTheComposerCameraDoor() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-pro", "--fuel", "--reset-fuel",
                               "--seed-fuel-photo", "--fuel-photo-demo"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 20), "Fuel page didn't appear.")
        // The resolved plate reads as its item list; the refused one carries the server's line
        // and no numbers.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Grilled Chicken'"))
            .firstMatch.waitForExistence(timeout: 10), "The resolved photo meal should show its items.")
        XCTAssertTrue(app.staticTexts["That photo doesn't look like a meal. Add the foods by hand, or try another photo."]
            .waitForExistence(timeout: 5), "The refused photo should carry the honest line.")
        // The demo plate went through the real lane: a durable row lands at once, titled for a
        // wordless photo, and then resolves to numbers or to the honest fallback.
        let photoRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Photo of a meal'")).firstMatch
        XCTAssertTrue(photoRow.waitForExistence(timeout: 15), "The photographed meal row did not land.")
        let numbers = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "≈", "g carbs ·"))
        let fallback = app.staticTexts["Couldn't estimate yet. Tap to set the numbers"]
        let resolved = NSPredicate { _, _ in fallback.exists || numbers.count > 0 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: resolved, object: nil)], timeout: 30),
                       .completed, "The photo estimate never resolved to numbers or the fallback.")
        // The refused plate shows the server's words ONCE, as its status line: at most the demo
        // row can carry the generic fallback.
        XCTAssertLessThanOrEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn't estimate")).count, 1,
                                 "A refused photo must not show the generic fallback beside its own line.")
        shot(app, "1-photo-rows")

        // The composer's camera glyph is the lane's one door; the library item is always there
        // (the camera item follows the device), and the door opens the system picker.
        let camera = app.descendants(matching: .any)["fuel-photo"].firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 5), "The camera glyph is missing from the composer.")
        camera.tap()
        let choose = app.buttons["Choose a photo"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5), "The camera menu should offer the library.")
        shot(app, "2-camera-menu")
        choose.tap()
        // The picker is system UI; give it a beat and record the screen, then let the test end.
        _ = app.otherElements.firstMatch.waitForExistence(timeout: 3)
        shot(app, "3-library-picker")
    }

    /// The chat box rides just above the keyboard (owner call 2026-09-07): focused, the whole
    /// composer is visible and its bottom edge sits a little clear of the keyboard's top.
    @MainActor
    func testComposerRidesJustAboveTheKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-pro", "--fuel", "--seed-fuel-today"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 20))
        let field = app.descendants(matching: .any)["fuel-composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 3) {
            field.tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 3), "The keyboard never came up.")
        }
        // Let the settle scroll land.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let gap = keyboard.frame.minY - field.frame.maxY
            return field.isHittable && gap >= 8 && gap <= 120
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: 4), .completed,
                       "Composer bottom \(field.frame.maxY) vs keyboard top \(keyboard.frame.minY): the chat box should sit just above the keyboard.")
        shot(app, "1-composer-above-keyboard")
    }

    /// The day strip: yesterday is a real page (its own empty state, its own composer prompt),
    /// and the name is the way home.
    @MainActor
    func testDayStripStepsBackAndHome() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-pro", "--fuel", "--reset-fuel"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 20))
        let prev = app.descendants(matching: .any)["fuel-day-prev"].firstMatch
        XCTAssertTrue(prev.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["fuel-day-next"].firstMatch.isEnabled,
                       "Today is the last page; there is no tomorrow.")
        prev.tap()
        let dayName = app.descendants(matching: .any)["fuel-day-label"].firstMatch
        let onYesterday = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Yesterday'"), object: dayName)
        XCTAssertEqual(XCTWaiter().wait(for: [onYesterday], timeout: 5), .completed, "Stepping back lands on yesterday.")
        XCTAssertTrue(app.staticTexts["Nothing logged yesterday"].waitForExistence(timeout: 5),
                      "A past empty day says unlogged, in a sentence.")
        XCTAssertFalse(app.descendants(matching: .any)["fuel-refuel-banner"].firstMatch.exists,
                       "The recovery window is a live thing; a past day never shows it.")
        shot(app, "1-yesterday")
        dayName.tap()
        let home = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Today'"), object: dayName)
        XCTAssertEqual(XCTWaiter().wait(for: [home], timeout: 5), .completed, "The name is the way home.")
        XCTAssertTrue(app.staticTexts["Nothing logged yet"].waitForExistence(timeout: 5))
    }
}
