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
        // Annual-only seven-day trial (owner call 2026-09-01). The fallback catalog is the DEBUG
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
        XCTAssertFalse(app.staticTexts["SAVE 90%"].exists,
                       "The savings badge must not compete with an active trial badge.")
        // The Marquee (2026-08-27) + weekly pricing (2026-08-28): plans are Yearly/Weekly cards (a11y
        // "Yearly plan, $0.58 per week, $29.99 billed yearly"), and the features are the marquee.
        // One-screen contract: both cards, the feature marquee, and the CTA — no scrolling.
        let yearly = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Yearly plan")).firstMatch
        let weekly = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Weekly plan")).firstMatch
        XCTAssertTrue(yearly.exists, "Yearly card not on the first screen.")
        XCTAssertTrue(weekly.exists, "Weekly card not on the first screen.")
        XCTAssertTrue(app.descendants(matching: .any)["Everything in Pro"].firstMatch.exists,
                      "The feature marquee is missing.")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/verify_paywall_top.png"))

        // Selecting weekly flips the CTA and the fine print to the weekly terms — the entry plan
        // never inherits the yearly's badge or its per-week framing.
        weekly.tap()
        XCTAssertTrue(app.buttons["Continue · $5.99/week"].waitForExistence(timeout: 5),
                      "CTA didn't follow the weekly selection.")
        XCTAssertFalse(app.buttons["Start my 7-day free trial"].exists,
                       "The weekly plan must not inherit the annual plan's trial.")
        XCTAssertTrue(app.staticTexts["$5.99/wk · cancel anytime"].waitForExistence(timeout: 5),
                      "Fine print didn't follow the weekly selection.")
    }
}
