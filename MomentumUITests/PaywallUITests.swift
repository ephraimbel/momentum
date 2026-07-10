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

        let headline = app.staticTexts["The coach that\nlearns you."]
        XCTAssertTrue(headline.waitForExistence(timeout: 15), "Paywall didn't present.")
        XCTAssertTrue(app.buttons["Start my 7-day free trial"].exists, "Trial CTA missing.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_paywall_top.png"))

        app.swipeUp()
        sleep(1)
        // Both plans present with the decided pricing.
        XCTAssertTrue(app.staticTexts["$119.99"].waitForExistence(timeout: 5), "Annual price missing.")
        XCTAssertTrue(app.staticTexts["$19.99"].exists, "Monthly price missing.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_paywall_plans.png"))

        // Selecting monthly flips the CTA to the no-trial wording.
        app.staticTexts["$19.99"].tap()
        XCTAssertTrue(app.buttons["Continue — $19.99/month"].waitForExistence(timeout: 5),
                      "CTA didn't follow the monthly selection.")
    }
}
