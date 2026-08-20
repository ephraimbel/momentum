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
        // The Film redesign (2026-08-20): plans are Yearly/Monthly capsules (combined a11y
        // "Yearly plan, $59.99 per year"), and the feature list lives behind "Everything in Pro".
        // One-screen contract: both capsules, the detail door, and the CTA — no scrolling.
        let yearly = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Yearly plan")).firstMatch
        let monthly = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Monthly plan")).firstMatch
        XCTAssertTrue(yearly.exists, "Yearly capsule not on the first screen.")
        XCTAssertTrue(monthly.exists, "Monthly capsule not on the first screen.")
        XCTAssertTrue(app.descendants(matching: .any)["Everything in Pro"].firstMatch.exists,
                      "The features door is missing.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_paywall_top.png"))

        // Selecting monthly flips to the no-trial wording — the trial is the annual's nudge only
        // (owner call 2026-07-30), so monthly must never promise one.
        monthly.tap()
        XCTAssertTrue(app.buttons["Continue · $9.99/month"].waitForExistence(timeout: 5),
                      "CTA didn't follow the monthly selection.")
        XCTAssertTrue(app.staticTexts["$9.99/mo · cancel anytime"].waitForExistence(timeout: 5),
                      "Fine print didn't follow the monthly selection.")
    }
}
