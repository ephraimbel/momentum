import XCTest

/// The two permission beats that follow the review (owner call 2026-09-12): Apple Health, then
/// location, then checkout. Every walker that crosses the review page crosses these too.
///
/// Both raise SYSTEM surfaces: HealthKit's sheet is hosted out of process (HealthPrivacyService on
/// iOS 26), location is a SpringBoard alert. A simulator that already answered either shows no
/// sheet and the beat advances on its own, so each crossing polls for the NEXT page rather than
/// insisting on the sheet; `resetAuthorizationStatus(for:)` before launch makes the sheet certain.
extension XCTestCase {

    /// Review → Health beat → location beat → whatever follows (checkout, or Today when entitled).
    func crossPermissionBeats(_ app: XCUIApplication) {
        crossHealthBeat(app)
        crossLocationBeat(app)
    }

    /// Answer the Health beat with Allow (Turn On All first when the sheet offers it).
    func crossHealthBeat(_ app: XCUIApplication, timeout: TimeInterval = 45) {
        let healthApp = XCUIApplication(bundleIdentifier: "com.apple.HealthPrivacyService")
        XCTAssertTrue(app.staticTexts["Train around your recovery"].waitForExistence(timeout: 15),
                      "the Health beat follows the review")
        // The page raises the sheet ITSELF on arrival (owner call 2026-09-13); Continue is the
        // fallback when iOS had nothing left to ask. Wait for the sheet first and tap Continue
        // only if none has come up.
        let next = app.buttons["Continue"].firstMatch
        let location = app.staticTexts["Map your runs"]
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var categoriesEnabled = false
        var tappedContinue = false
        while Date() < deadline, !location.exists {
            // Querying an absent cross-process element is the slow case; touch the Health
            // process only while it is in front.
            if healthApp.state == .runningForeground {
                grantHealthSheet(healthApp, categoriesEnabled: &categoriesEnabled)
            } else if !tappedContinue, Date().timeIntervalSince(started) > 3, next.exists, next.isHittable {
                next.tap()
                tappedContinue = true
            }
            usleep(300_000)
        }
        XCTAssertTrue(location.exists, "the location beat follows Health")
    }

    /// Answer the location beat with Allow While Using App.
    func crossLocationBeat(_ app: XCUIApplication, timeout: TimeInterval = 20) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(app.staticTexts["Map your runs"].waitForExistence(timeout: 15))
        // The page raises the alert ITSELF on arrival; Continue is the fallback.
        let next = app.buttons["Continue"].firstMatch
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var tappedContinue = false
        while Date() < deadline {
            if springboard.alerts.firstMatch.exists {
                for label in ["Allow While Using App", "Allow Once", "Allow", "OK"] {
                    let allow = springboard.buttons[label]
                    if allow.exists && allow.isHittable { allow.tap(); return }
                }
            } else if !tappedContinue, Date().timeIntervalSince(started) > 3, next.exists, next.isHittable {
                next.tap()
                tappedContinue = true
            }
            // No alert: the simulator had already answered and the beat moved on.
            if !app.staticTexts["Map your runs"].exists { return }
            usleep(300_000)
        }
    }

    @discardableResult
    func grantHealthSheet(_ healthApp: XCUIApplication, categoriesEnabled: inout Bool) -> Bool {
        var interacted = false
        if !categoriesEnabled {
            let allCategories = healthApp.cells["UIA.Health.AuthSheet.AllCategoryButton"]
            if allCategories.exists && allCategories.isHittable {
                allCategories.tap(); categoriesEnabled = true; interacted = true
            } else {
                let allText = healthApp.staticTexts["Turn On All"]
                if allText.exists && allText.isHittable { allText.tap(); categoriesEnabled = true; interacted = true }
            }
            if !categoriesEnabled {
                for label in ["Turn On All", "Turn On All Categories", "Enable All"] {
                    let control = healthApp.switches[label].exists ? healthApp.switches[label] : healthApp.buttons[label]
                    if control.exists && control.isHittable { control.tap(); categoriesEnabled = true; interacted = true; break }
                }
            }
        }
        let allow = healthApp.buttons["Allow"]
        guard allow.exists && allow.isHittable else { return interacted }
        allow.tap()
        categoriesEnabled = false
        return true
    }
}
