import XCTest

/// The hand-off the owner asked for (2026-08-28): the athlete grants location at onboarding's
/// "Map your runs" beat, and the Today map they land on is centred on them — never a zoomed-out
/// world map. Before this, onboarding and Today each owned a private `LocationService`, so the
/// grant (and the fix that came with it) never reached the map.
///
/// A LIVE permission test: it taps the real system alert. It deliberately stops at the grant and
/// re-enters at Today rather than walking the paywall and account beats — those are covered by
/// their own suites, and driving them here made this test about presentation timing instead of
/// about location.
final class OnboardingLocationHandoffUITests: XCTestCase {

    func testGrantingAtOnboardingLeavesTodayLocated() {
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding", "--onboarding-primers"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 25),
                      "the location beat should be on screen")

        // The system alert belongs to SpringBoard, so it is queried there, not in the app. When the
        // simulator already holds a grant from an earlier run the alert never appears — that's the
        // "already authorized" path, equally valid here, so don't fail on it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 12) { allow.tap() }

        // Re-enter at Today, exactly where the flow hands off.
        app.terminate()
        // `--seed-empty`, deliberately: with seeded history `lastKnownCoordinate` alone would
        // satisfy the assertion below and the test would pass even if the grant never arrived.
        // No workouts means the map can only be located by the permission we just granted.
        app.launchArguments = ["--seed-empty", "--today-sport", "run"]
        app.launch()

        XCTAssertTrue(app.buttons["Start run"].waitForExistence(timeout: 30), "Today should be up")
        // The map chrome a LOCATED map carries. `canCenterMap` gates this control on having
        // permission or a known coordinate, so its presence is the assertion that the grant
        // reached the map's service.
        XCTAssertTrue(app.buttons["Recenter on my location"].waitForExistence(timeout: 15),
                      "the grant never reached Today's map — it opened unlocated")

        if let dir = ProcessInfo.processInfo.environment["MOMENTUM_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding-to-today.png"))
        }
    }
}
