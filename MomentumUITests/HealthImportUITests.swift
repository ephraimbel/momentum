import XCTest

/// Live end-to-end check of the Apple Health **import** (Garmin/Watch → our store). `--health-e2e`
/// boots straight into `HealthE2EView`, which requests Health auth, seeds synthetic *foreign*
/// workouts, runs the real import against `HKHealthStore`, and writes the result into the
/// `health-e2e-status` label. This test taps through the Health authorization sheet, then asserts the
/// round-trip actually imported workouts — the part unit tests can't cover.
final class HealthImportUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testImportsForeignWorkoutsFromHealth() {
        let app = XCUIApplication()
        app.launchArguments = ["--health-e2e"]

        // The Health authorization sheet is a separate process — grab it by bundle id.
        addUIInterruptionMonitor(withDescription: "Health auth") { sheet in
            self.grantHealth(in: sheet)
        }
        app.launch()

        // The auth sheet should appear; grant it. Tapping the app first nudges the interruption
        // monitor; we also try the sheet directly via the Health UI service.
        let status = app.staticTexts["health-e2e-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "E2E probe view never appeared.")

        // Give the sheet a beat to present, then handle it (monitor + direct).
        let health = XCUIApplication(bundleIdentifier: "com.apple.Health")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if status.label.contains("RESULT") { break }
            app.tap()                       // fire the interruption monitor
            _ = grantHealth(in: health)     // and try the sheet process directly
            usleep(500_000)
        }

        XCTAssertTrue(status.label.contains("RESULT"),
                      "Health probe never produced a result — auth sheet likely not dismissed.")
        // auth must have been granted…
        XCTAssertTrue(status.label.contains("auth=ok"),
                      "Health authorization was not granted: \(status.label)")
        // …and the import must have pulled in the seeded foreign workouts.
        let imported = Self.intValue(after: "imported=", in: status.label)
        XCTAssertGreaterThanOrEqual(imported, 1,
                                    "Import brought in no workouts: \(status.label)")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "health-import-result"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Tap "Turn On All" + "Allow" in whatever process is presenting the Health sheet.
    @discardableResult
    private func grantHealth(in element: XCUIElement) -> Bool {
        var acted = false
        for label in ["Turn On All", "Turn On All Categories", "Enable All"] {
            let sw = element.switches[label]
            if sw.exists && sw.isHittable { sw.tap(); acted = true }
            let btn = element.buttons[label]
            if btn.exists && btn.isHittable { btn.tap(); acted = true }
        }
        for label in ["Allow", "Don’t Allow"] {   // Allow first; never tap "Don't Allow"
            let btn = element.buttons[label]
            if label == "Allow" && btn.exists && btn.isHittable { btn.tap(); acted = true }
        }
        return acted
    }

    @discardableResult
    private func grantHealth(in app: XCUIApplication) -> Bool {
        grantHealth(in: app as XCUIElement)
    }

    private static func intValue(after token: String, in s: String) -> Int {
        guard let r = s.range(of: token) else { return -1 }
        let tail = s[r.upperBound...].prefix { $0.isNumber }
        return Int(tail) ?? -1
    }
}
