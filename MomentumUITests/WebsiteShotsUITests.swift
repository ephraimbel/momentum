import XCTest

/// Marketing-shot dumper (not a regression test — run explicitly when the website needs fresh
/// captures). Walks the seeded app and writes PNGs of the surfaces the site showcases.
final class WebsiteShotsUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad/site"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
    }

    /// Today (hero), Plan (periodization), Coach chat — tab/nav walk.
    func testDumpTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launch()
        // A previous (crashed) run can leave the interrupted-workout marker — clear the recovery
        // prompt so it never photobombs a marketing shot.
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 4) { discard.tap(); sleep(1) }
        sleep(6)   // map tiles
        dump(app, "hero-today")

        app.buttons["Plan"].firstMatch.tap()
        sleep(3)
        dump(app, "plan")

        // Profile grid — the athlete's wall of route/muscle art tiles.
        app.buttons["Profile"].firstMatch.tap()
        sleep(4)   // Mapbox route snapshots render into the tiles
        dump(app, "profile-grid")

        // Progress → Trends (fitness hero, zones, charts).
        app.buttons["Progress"].firstMatch.tap()
        sleep(3)
        dump(app, "progress")

        app.buttons["Profile"].firstMatch.tap()
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.tap()
        let chat = app.staticTexts["Open coach chat"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10))
        sleep(1)
        dump(app, "coach")
    }

    /// A live guided run with the simulated GPS route + simulated HR (zone chip, bpm, step banner).
    func testDumpLiveRun() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--ui-test-route", "--ui-test-structured-run", "--demo-hr"]
        app.launch()

        let pause = app.buttons["Pause"]
        let startNow = app.buttons["Start now"]
        let deadline = Date().addingTimeInterval(25)
        while !pause.exists && Date() < deadline {
            if startNow.exists && startNow.isHittable { startNow.tap() }
            usleep(300_000)
        }
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Never reached tracking.")
        sleep(20)   // let the trace draw and HR ramp
        dump(app, "live-run")
    }
}
