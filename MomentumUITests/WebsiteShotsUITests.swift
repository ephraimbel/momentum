import XCTest

/// Marketing-shot dumper (not a regression test — run explicitly when the website needs fresh
/// captures). Walks the seeded app and writes PNGs of the surfaces the site showcases.
final class WebsiteShotsUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/9e5489bb-10b4-4631-a8cd-f5b4f9789f6e/scratchpad/site"

    /// The website now showcases the app's DARK look. Every shot launches in forced dark via
    /// `-com.momentum.appearance dark` — an EXPLICIT preference (not System), which also sidesteps
    /// the System-appearance feed-invalidation loop. Flip to `[]` to shoot the light theme again.
    private let darkArgs = ["-com.momentum.appearance", "dark"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WEBSITE_SHOTS"] == "1",
                          "Website capture rig; set TEST_RUNNER_WEBSITE_SHOTS=1 to run")
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
    }

    /// Today (hero), Plan (periodization), Coach chat — tab/nav walk.
    func testDumpTabs() {
        let app = XCUIApplication()
        app.launchArguments = darkArgs + ["--seed-demo"]
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

    /// The website HEADER shot: the POST-RUN summary of a finished Austin Marathon — the real course
    /// on the route map + the finish data (26.2 mi · 2:58:41 · 6:49/mi). Runna-style "you did it" hero.
    func testDumpHero() {
        let app = XCUIApplication()
        app.launchArguments = darkArgs + ["--seed-demo", "--marathon-hero", "--ui-test-run-detail"]
        app.launch()
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 4) { discard.tap(); sleep(1) }
        sleep(9)   // detail presents + the route map draws the marathon on the dark basemap
        dump(app, "hero-route")
    }

    /// A live run mid-flight: `--live-run-midway` fast-forwards the simulated GPS to ~2 mi (real route
    /// drawn, distance well past 0.0, backdated clock so the pace/time read coherently) with simulated
    /// HR. A free run (--live-run) tracks regardless of the permission dialogs, unlike a structured run.
    func testDumpLiveRun() {
        let app = XCUIApplication()
        app.launchArguments = darkArgs + ["--seed-demo", "--live-run", "--ui-test-route", "--demo-hr", "--live-run-midway"]
        app.launch()

        // Dismiss both photobombing springboard dialogs (Location, then Motion & Fitness) as they
        // appear — the run tracks underneath them regardless.
        // Permissions are pre-granted via `simctl privacy grant` before this runs, so usually no
        // dialog appears. `waitForExistence` (not a tight `.exists` poll, which throws a springboard
        // snapshot error under load) mops up any that still slip through — Location then Motion.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowLocation = springboard.buttons["Allow While Using App"]
        if allowLocation.waitForExistence(timeout: 6) { allowLocation.tap() }
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        sleep(26)   // lap draws under follow-cam (~16 s), then the overview re-frames the full loop
        dump(app, "live-run")
    }

    /// The Profile screen as a FULL, established account — a marathoner's wall of real-route tiles
    /// with a deep follower/following/posts trio. `--marketing-profile` seeds ~200 posts and renders
    /// Mapbox tiles (dark basemap in dark mode) for the visible top of the grid.
    func testDumpMarketingProfile() {
        let app = XCUIApplication()
        app.launchArguments = darkArgs + ["--seed-demo", "--marketing-profile"]
        app.launch()
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 4) { discard.tap(); sleep(1) }
        app.buttons["Profile"].firstMatch.tap()
        // The seed renders ~22 route tiles sequentially on the GPU — give it room before the shot.
        sleep(22)
        dump(app, "profile-grid")
    }

    /// The personal heatmap — the full `PersonalHeatmapView` on a dark map (Progress → History →
    /// auto-expanded via `--heatmap-expand`).
    func testDumpHeatmap() {
        let app = XCUIApplication()
        // Force the persisted map style to the Dark basemap (HeatmapMapView uses the non-adaptive
        // styleURI), so the heatmap renders on a dark map to match the site.
        app.launchArguments = darkArgs + ["-com.momentum.mapStyle", "dark",
                                          "--seed-demo", "--progress-history", "--heatmap-expand"]
        app.launch()
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 4) { discard.tap(); sleep(1) }
        app.buttons["Progress"].firstMatch.tap()
        sleep(9)   // History renders, the heatmap auto-expands, map tiles + heat layer draw
        dump(app, "heatmap-dark")
    }

    /// The AI coach chat — the "your week in review" read plus a seeded plan-change proposal card.
    func testDumpCoach() {
        let app = XCUIApplication()
        app.launchArguments = darkArgs + ["--seed-demo", "--coach-card"]
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

    /// Post-run pace review: the guided-run rep breakdown (6×400 with on/slow verdicts) + the coach's
    /// "Right on your targets" read. `--ui-test-run-detail` opens the seeded reps run; `--detail-scroll-reps`
    /// frames the reps + pace-review card.
    func testDumpPaceReview() {
        let app = XCUIApplication()
        app.launchArguments = darkArgs + ["--seed-demo", "--ui-test-run-detail", "--detail-scroll-reps"]
        app.launch()
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 4) { discard.tap(); sleep(1) }
        sleep(6)   // detail presents + scroll-to-reps animates + route map settles
        dump(app, "pace-review")
    }
}
