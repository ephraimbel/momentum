import XCTest

/// The Pro paywall (premium redesign 2026-07-10): full feature list, both plan cards, and the
/// trial CTA all reachable. Dumps PNGs of both scroll states for visual inspection.
@MainActor
final class PaywallUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/dab5c7b2-3f47-4a9d-a69d-e9360d163b0c/scratchpad"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testPaywallShowsFeaturesPlansAndTrialCTA() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-free", "--paywall"]
        app.launch()

        let headline = app.staticTexts["Run smarter.\nRace faster."]
        XCTAssertTrue(headline.waitForExistence(timeout: 15), "Paywall didn't present.")
        // Annual-only seven-day trial (owner call 2026-09-11). The fallback catalog is the DEBUG
        // contract; production derives this eligibility and the localized renewal price from StoreKit.
        XCTAssertTrue(app.buttons["Start my 7-day free trial"].exists,
                      "The annual trial CTA is missing.")
        XCTAssertFalse(app.buttons["Continue · $29.99/year"].exists,
                       "The annual plan must not charge immediately while its trial is eligible.")
        XCTAssertTrue(app.staticTexts["No payment due now"].exists,
                      "The trial must say plainly that payment is not due today.")
        XCTAssertTrue(app.staticTexts["7 days free, then $29.99/yr · cancel anytime"].exists,
                      "The annual trial's renewal terms are missing or ambiguous.")
        XCTAssertTrue(app.staticTexts["7 DAYS FREE"].exists,
                      "The annual card must foreground its active trial.")
        XCTAssertFalse(app.staticTexts["SAVE 75%"].exists,
                       "The savings badge must not compete with an active trial badge.")
        // The Marquee (2026-08-27) + monthly pricing (2026-09-07): plans are Yearly/Monthly cards (a11y
        // "Yearly plan, $2.50 per month, $29.99 billed yearly"), and the features are the marquee.
        // One-screen contract: both cards, the feature marquee, and the CTA — no scrolling.
        let yearly = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Yearly plan")).firstMatch
        let monthly = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Monthly plan")).firstMatch
        XCTAssertTrue(yearly.exists, "Yearly card not on the first screen.")
        XCTAssertTrue(monthly.exists, "Monthly card not on the first screen.")
        XCTAssertTrue(app.descendants(matching: .any)["Everything in Pro"].firstMatch.exists,
                      "The feature marquee is missing.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_paywall_top.png"))

        // Selecting monthly flips the CTA and the fine print to the monthly terms — the entry plan
        // never inherits the yearly's badge or its per-month framing.
        monthly.tap()
        XCTAssertTrue(app.buttons["Continue · $9.99/month"].waitForExistence(timeout: 5),
                      "CTA didn't follow the monthly selection.")
        XCTAssertFalse(app.buttons["Start my 7-day free trial"].exists,
                       "The monthly plan must not inherit the annual plan's trial.")
        XCTAssertTrue(app.staticTexts["$9.99/mo · cancel anytime"].waitForExistence(timeout: 5),
                      "Fine print didn't follow the monthly selection.")
    }
}
