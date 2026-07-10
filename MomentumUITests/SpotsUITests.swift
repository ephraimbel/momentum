import XCTest

/// End-to-end check of "Spots near you" against the **real** Mapbox Search API (PRD §6): the sheet
/// loads ranked spots (the nearest is auto-selected, revealing its actions), and the Run/Hike filter
/// re-ranks live. Uses the `--spots` deep link for a deterministic open. Screenshots are attached.
final class SpotsUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testSpotsLoadFilterAndSelect() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--spots"]
        app.launch()

        // Sheet opens.
        XCTAssertTrue(app.staticTexts["Spots near you"].waitForExistence(timeout: 20),
                      "Spots sheet didn't open.")
        XCTAssertTrue(app.buttons["Run"].waitForExistence(timeout: 15), "Filter pills missing.")

        // Real spots loaded from the network: the nearest is auto-selected, so its actions show.
        let loopHere = app.buttons["Loop here"]
        XCTAssertTrue(loopHere.waitForExistence(timeout: 20),
                      "No spots loaded / none selected — 'Loop here' never appeared.")
        XCTAssertTrue(app.buttons["Directions"].exists, "'Directions' action missing.")
        attach(app, "spots-run")

        // Hike filter re-ranks (trails/peaks/reserves) and keeps a populated, selected list.
        app.buttons["Hike"].tap()
        XCTAssertTrue(loopHere.waitForExistence(timeout: 10),
                      "Hike filter produced no selectable spots.")
        attach(app, "spots-hike")

        // "Loop here" hands the spot to the loop suggester, seeded at that spot (park-biased loops):
        // the route-suggestion sheet opens with its distance picker.
        loopHere.tap()
        sleep(4)
        attach(app, "spots-loop-here")
        let opened = app.buttons["5K"].exists || app.staticTexts["5K"].exists
            || app.buttons["Shuffle"].exists || app.staticTexts["Finding loops near you…"].exists
        XCTAssertTrue(opened, "'Loop here' didn't open the loop suggester at the spot.")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
