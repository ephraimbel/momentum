import XCTest

/// Pins the Podium tier's selection contract in Plan settings: picking Podium lifts the week to
/// the tier's 5-day floor and says so in plain words right under the cards.
final class PodiumSelectionUITests: XCTestCase {

    @MainActor
    func testPickingPodiumLiftsDaysToTheFloorAndSaysSo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--plan-tab", "--plan-settings"]
        app.launch()

        let podium = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Podium")).firstMatch
        XCTAssertTrue(podium.waitForExistence(timeout: 12), "Podium card missing from plan settings")
        // The card sits mid-sheet — scroll until it's hittable, then pick it.
        var attempts = 0
        while !podium.isHittable && attempts < 6 { app.swipeUp(); attempts += 1 }
        podium.tap()

        let note = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Podium trains 5+ days")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 4), "the day-floor note should follow the pick")
        XCTAssertTrue(note.label.contains("your week is set to 5"),
                      "picking Podium on a 4-day week must lift the week to the 5-day floor")
    }
}
