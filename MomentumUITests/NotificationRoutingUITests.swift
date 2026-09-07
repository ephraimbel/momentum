import XCTest

/// A tapped notification opens what it was about (notification pass 2026-09-06), never just the
/// app. `--notify-open=<route>` stands in for the tap and goes through the same door the push
/// delegate uses (`NotificationService.open` → `AppRouter.pendingNotificationRoute` → the shell),
/// so these drive the real consumer path: the tab switch, the per-tab mailbox, and the sheet or
/// push it opens.
final class NotificationRoutingUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(_ route: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--awards-quiet", "--notify-open=\(route)"] + extra
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        return app
    }

    /// A session reminder opens THAT session: the Plan tab, its week, its detail sheet with Start.
    @MainActor
    func testSessionReminderOpensTheSessionSheet() {
        let app = launch("plan.session")
        // Today's own control is "Start run"; the bare "Start" belongs to the session sheet.
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 25),
                      "A session reminder must open the session's own sheet, not just the app.")
        // The Start sits inside a presented sheet (its grabber is the proof), with the sheet's
        // own close control beside the masthead.
        XCTAssertTrue(app.buttons["Sheet Grabber"].waitForExistence(timeout: 5),
                      "The session must open as a sheet over the Plan board.")
        XCTAssertTrue(app.buttons["Close"].exists, "The sheet carries its own close control.")
    }

    /// The morning readiness push (and an easing) lands on Progress · Health.
    @MainActor
    func testReadinessOpensProgressHealth() {
        let app = launch("progress:Health")
        let health = app.buttons["Health"]
        XCTAssertTrue(health.waitForExistence(timeout: 25), "Progress must be on screen with its segments.")
        XCTAssertTrue(health.isSelected, "The Health segment must be the selected one.")
    }

    /// The trial reminder lands on Settings (Manage subscription lives there).
    @MainActor
    func testTrialReminderOpensSettings() {
        let app = launch("settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 25),
                      "The trial reminder must push Settings on the Profile tab.")
    }

    /// The end-to-end proof: a REAL local notification, tapped on SpringBoard with the app in the
    /// background, must come through the delegate and land on its destination. The four tests
    /// above verify the shell from the service's door inward; this one verifies the door itself.
    /// Needs a FRESH INSTALL (`xcrun simctl uninstall <udid> com.ephraimbel.momentum.app` first):
    /// iOS asks for notification permission once per install, and an abandoned alert from an
    /// earlier run counts as answered, after which no banner can ever present.
    @MainActor
    func testATappedBannerRoutesThroughTheDelegate() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--awards-quiet",
                               "--notify-authorize", "--notify-fire=progress:Health"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        // The permission alert lands after the splash, so wait for it and answer it directly
        // (the interruption monitor above is a fallback; it only runs on the next interaction).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // iOS asks once per install: on a fresh install the alert appears after the splash (slow
        // on a first launch) and is answered here; when an earlier test in this run already
        // allowed it there is no alert. The notification is scheduled only when the app goes to
        // the background, so waiting here costs nothing but time.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 20) { allow.tap() }
        sleep(1)
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'routing check'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20),
                      "The local notification must present as a banner on SpringBoard.")
        banner.tap()
        // The delegate decoded the route and the shell followed it.
        let health = app.buttons["Health"]
        XCTAssertTrue(health.waitForExistence(timeout: 20), "Tapping the banner must reopen the app on Progress.")
        XCTAssertTrue(health.isSelected, "The Health segment must be the selected one after the tap.")
    }

    /// After an exerting session, Fuel itself says why you are there: the refuel banner carries the
    /// notification's own words, and it opens the composer.
    @MainActor
    func testFuelShowsTheRefuelWindowAfterAnExertingRun() {
        let app = launch("fuel", extra: ["--seed-refuel"])
        let banner = app.buttons["fuel-refuel-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 25), "Fuel must show the refuel banner after a long run.")
        XCTAssertTrue(banner.label.hasPrefix("Refuel after that run"), "Got: \(banner.label)")
        XCTAssertFalse(banner.label.contains { $0.isNumber }, "The banner never names an amount.")
        banner.tap()
        XCTAssertTrue(app.textFields["fuel-composer"].waitForExistence(timeout: 5))
    }

    /// The refuel cue, end to end through the production path: a long run is saved, the cue is
    /// scheduled by `scheduleRefuelCue`, its banner is tapped on SpringBoard, and the app lands on
    /// Fuel with the refuel window open and speaking the same words. Needs a fresh install (see
    /// `testATappedBannerRoutesThroughTheDelegate`).
    @MainActor
    func testARefuelCueFiresThroughTheProductionPathAndOpensFuel() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--awards-quiet",
                               "--notify-authorize", "--refuel-fire"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 20) { allow.tap() }   // absent when already allowed this run
        sleep(1)
        XCUIDevice.shared.press(.home)   // the cue is scheduled on backgrounding and fires ~4s later
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Refuel after that run'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 25),
                      "The refuel cue must present as a banner after the run.")
        banner.tap()
        let window = app.buttons["fuel-refuel-banner"]
        XCTAssertTrue(window.waitForExistence(timeout: 20),
                      "Tapping the cue must open Fuel with the refuel window open.")
        XCTAssertTrue(window.label.hasPrefix("Refuel after that run"),
                      "Fuel speaks the notification's own words. Got: \(window.label)")
    }

    /// A Siri meal receipt lands on Fuel.
    @MainActor
    func testMealReceiptOpensFuel() {
        let app = launch("fuel")
        XCTAssertTrue(app.staticTexts["fuel"].waitForExistence(timeout: 25),
                      "The meal receipt must open the Fuel page.")
    }
}
