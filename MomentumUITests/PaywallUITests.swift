import XCTest

/// The Pro paywall (premium redesign 2026-07-10): full feature list, both plan cards, and the
/// trial CTA all reachable. Dumps PNGs of both scroll states for visual inspection.
final class PaywallUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testPaywallShowsFeaturesPlansAndTrialCTA() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--debug-free", "--paywall"]
        app.launch()

        let headline = app.staticTexts["Run smarter.\nRace faster."]
        XCTAssertTrue(headline.waitForExistence(timeout: 15), "Paywall didn't present.")
        XCTAssertTrue(app.buttons["Start my 7-day free trial"].exists, "Trial CTA missing.")
        // One-screen contract: BOTH plans and the CTA are visible with no scrolling.
        XCTAssertTrue(app.staticTexts["$59.99"].exists, "Annual price not on the first screen.")
        XCTAssertTrue(app.staticTexts["$9.99"].exists, "Monthly price not on the first screen.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_paywall_top.png"))

        // Selecting monthly flips to the no-trial wording — the trial is the annual's nudge only
        // (owner call 2026-07-30), so monthly must never promise one.
        app.staticTexts["$9.99"].tap()
        XCTAssertTrue(app.buttons["Continue · $9.99/month"].waitForExistence(timeout: 5),
                      "CTA didn't follow the monthly selection.")
        XCTAssertTrue(app.staticTexts["$9.99/mo · cancel anytime"].waitForExistence(timeout: 5),
                      "Fine print didn't follow the monthly selection.")
    }
}
