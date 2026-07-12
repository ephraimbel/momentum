import XCTest

/// Marketing-shot dumper (not a regression test — run explicitly when the website needs fresh
/// captures). Walks the seeded app and writes PNGs of the surfaces the site showcases.
final class WebsiteShotsUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/9e5489bb-10b4-4631-a8cd-f5b4f9789f6e/scratchpad/site"

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

    /// The website HEADER shot: the Today map with a real seeded run traced on it (route) AND
    /// today's plan card — the Runna-style "route + plan" hero, in one authentic app screen.
    func testDumpHero() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--marketing-hero"]
        app.launch()
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 4) { discard.tap(); sleep(1) }
        sleep(9)   // style load + tiles + route draw + overview camera settle
        dump(app, "hero-route")
    }

    /// A live run with the simulated GPS route drawing + simulated HR (live pace, time, HR zone).
    /// A free run (--live-run) tracks regardless of the permission dialogs, unlike a structured
    /// run which stalls in "acquiring" behind them — so this is the robust capture.
    func testDumpLiveRun() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--live-run", "--ui-test-route", "--demo-hr"]
        app.launch()

        // Dismiss both photobombing springboard dialogs (Location, then Motion & Fitness) as they
        // appear — the run tracks underneath them regardless.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        let allowLocation = springboard.buttons["Allow While Using App"]
        for _ in 0..<20 {
            if allowLocation.exists && allowLocation.isHittable { allowLocation.tap() }
            if allow.exists && allow.isHittable { allow.tap() }
            usleep(400_000)
        }
        sleep(16)   // let the route trace draw and HR ramp
        // Final sweep in case a dialog re-armed, then shoot.
        if allowLocation.exists && allowLocation.isHittable { allowLocation.tap() }
        if allow.exists && allow.isHittable { allow.tap() }
        sleep(2)
        dump(app, "live-run")
    }

    /// The AI coach chat — the "your week in review" read plus a seeded plan-change proposal card.
    func testDumpCoach() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--coach-card"]
        app.launch()

        // Motion & Fitness permission (springboard) can pop over the chat — dismiss it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        sleep(2)
        // The composer auto-focuses → keyboard up, covering half the thread. The transcript uses
        // .scrollDismissesKeyboard(.interactively), so a downward drag pushes the keyboard away;
        // a gentle one keeps the "Ease this week" proposal card in frame.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        top.press(forDuration: 0.1, thenDragTo: low)
        sleep(2)
        dump(app, "coach")
    }
}
