import XCTest

/// The FUEL loop, end to end on the tab: log a meal by sentence → the estimate path resolves
/// (offline/undeployed → the graceful "set the numbers" fallback) → manual numbers via the edit
/// sheet → the day's readout rolls to the new total. Screenshots at each beat.
final class FuelFlowUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testLogEditAndReadoutLoop() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--fuel", "--reset-fuel"]
        app.launch()

        // The deep link lands on the Fuel tab.
        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 20), "Fuel page didn't appear.")
        XCTAssertTrue(app.tabBars.buttons["Fuel"].exists, "Fuel tab missing from the bar.")
        shot(app, "1-fuel-empty")

        // Log a meal by sentence. (The composer is a vertical-axis TextField — match by placeholder
        // across element types so the query survives how XCUITest surfaces it.)
        let byPlaceholder = NSPredicate(format: "placeholderValue BEGINSWITH %@", "What did you eat?")
        let field = app.descendants(matching: .any).matching(byPlaceholder).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Composer field not found.")
        field.tap()
        // The entry reveal-cascade can swallow the first tap's focus — retap until the keyboard
        // confirms it (typeText without focus hard-fails the run).
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        }
        field.typeText("big pasta dinner with chicken")
        shot(app, "1a-composer-glow")   // the iridescent ring while writing (coach-composer match)
        app.buttons["Log meal"].tap()

        // The row lands instantly (offline-first), then the estimate resolves — to REAL numbers when
        // the deployed function is reachable, or to the honest set-it-yourself fallback when not.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "big pasta dinner")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Logged meal row didn't appear.")
        let fallback = app.staticTexts["Couldn't estimate — tap to set the numbers"]
        // The ROW's numbers line ("≈54 g carbs · 620 kcal · …") — the "g carbs ·" separator is what
        // distinguishes it from the readout strip's "≈0 of 350 g carbs" line. Matching anything
        // looser resolves this wait instantly and taps the row while it's still estimating
        // (estimating rows deliberately don't open the sheet).
        let numbers = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "≈", "g carbs ·")).firstMatch
        let resolved = NSPredicate { _, _ in fallback.exists || numbers.exists }
        let wait = XCTNSPredicateExpectation(predicate: resolved, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 25), .completed,
                       "Pending estimate never resolved (neither numbers nor fallback).")
        shot(app, "2-meal-logged-resolved")

        // Set the numbers by hand — carbs first field in the edit sheet. A live estimate opens the
        // sheet in ITEMS mode (portion steppers); "Set totals by hand" swaps to the direct fields.
        // An offline/fallback meal has no items and opens on the fields directly — handle both.
        row.tap()
        XCTAssertTrue(app.navigationBars["Meal"].waitForExistence(timeout: 8), "Edit sheet didn't open.")
        let switchToTotals = app.buttons["Set totals by hand"]
        if switchToTotals.waitForExistence(timeout: 3) {
            shot(app, "3a-items-portions")   // per-item rows + qty steppers (the Amy beat)
            switchToTotals.tap()
        }
        let carbsField = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "—")).element(boundBy: 0)
        XCTAssertTrue(carbsField.waitForExistence(timeout: 5), "Carbs field not found.")
        // A live estimate may have pre-filled the field, so typing must REPLACE the number.
        // Focus is a SINGLE tap first — a doubleTap on an unfocused field can register as a
        // text gesture without ever raising the keyboard — then the doubleTap selects the
        // existing number once focus is confirmed. Settle first: switching to totals mode
        // grows the sheet to .large (so the fields are never under the medium fold) and that
        // transition animates; a tap mid-shift misses.
        Thread.sleep(forTimeInterval: 0.8)
        carbsField.tap()
        var focusTries = 0
        while !app.keyboards.firstMatch.waitForExistence(timeout: 2), focusTries < 2 {
            focusTries += 1
            carbsField.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Carbs field never took keyboard focus.")
        carbsField.doubleTap()   // select the prefilled number (field already focused)
        carbsField.typeText("150")
        shot(app, "3-edit-sheet")
        app.buttons["Save"].tap()

        // The readout strip rolls to the manual total ("Building · ≈150 of 350 g carbs").
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "≈150 of"))
            .firstMatch.waitForExistence(timeout: 8),
                      "Readout strip didn't update to the manual entry.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "≈150 g carbs"))
            .firstMatch.waitForExistence(timeout: 5), "Meal row numbers line didn't update.")
        shot(app, "4-readout-updated")

        // One-tap repeat: the logged meal is now a "usual" chip; tapping re-logs it instantly
        // (numbers copied, no estimate round-trip) and the day's carbs double. The strip reads
        // "≈300 of X g carbs" while under the day's floor or "≈300 g carbs banked" once past it —
        // and the floor moves with the seeded plan's session horizon (350 on a long-run eve, 210
        // on an easy one), so BOTH are legitimate outcomes of this seed. Match strictly on the
        // two strip phrasings; a plain "≈300" would also match nothing else, but strictness here
        // is what keeps this from passing on a stale strip plus a lucky row.
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Log again:")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "Usuals chip didn't appear.")
        chip.tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "≈300 of", "≈300 g carbs banked"))
            .firstMatch.waitForExistence(timeout: 6), "Repeat log didn't roll the strip to ≈300.")
        shot(app, "4a-usual-repeated")

        // History: the top-right calendar opens the day-by-day journal with today's meal in it,
        // organized under month headers with an always-visible search field.
        app.buttons["Meal history"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 6), "History page didn't open.")
        XCTAssertTrue(app.staticTexts["TODAY"].waitForExistence(timeout: 4), "Today's section missing in history.")
        shot(app, "5-history")

        // Search narrows to matching meals; a nonsense query lands the honest empty state.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 4), "History search field missing.")
        search.tap()
        search.typeText("pasta")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "big pasta dinner"))
            .firstMatch.waitForExistence(timeout: 4), "Search didn't surface the pasta meal.")
        shot(app, "5a-history-search")
    }

    /// History at real scale: months of seeded journal days organize under sticky month headers
    /// with per-month counts, and search narrows across all of it.
    func testHistoryAtScale() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--reset-fuel", "--seed-fuel-history", "--fuel"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Fuel"].waitForExistence(timeout: 20), "Fuel tab missing.")
        app.buttons["Meal history"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 6), "History didn't open.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "days logged"))
            .firstMatch.waitForExistence(timeout: 6), "Month headers missing at scale.")
        shot(app, "7-history-months")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 4), "Search field missing.")
        search.tap()
        search.typeText("salmon")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "salmon"))
            .firstMatch.waitForExistence(timeout: 4), "Search didn't find seeded salmon meals.")
        shot(app, "7a-history-months-search")
    }

    /// The fueling adjuster: open from the top-left, choose Leaner, save — the energy headline
    /// flips from the classic floor ("+ kcal") to a goal ("kcal today").
    func testFuelingGoalsAdjuster() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--fuel", "--reset-fuel", "--seed-plan-name"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Fuel"].waitForExistence(timeout: 20), "Fuel tab missing.")

        app.buttons["Fueling goals"].tap()
        XCTAssertTrue(app.navigationBars["Fueling goals"].waitForExistence(timeout: 6), "Adjuster didn't open.")
        // The default option wears the athlete's own plan by name.
        XCTAssertTrue(app.staticTexts["Fuel for the Austin Marathon"].waitForExistence(timeout: 4),
                      "Goal card didn't pick up the plan name.")
        shot(app, "6-goals-sheet")
        app.buttons["goal-leaner"].firstMatch.tap()
        shot(app, "6a-goals-leaner")
        app.buttons["Save"].tap()

        // The headline's caption flips to the goal phrasing: the floor reads "of 2,650+ kcal",
        // a chosen goal reads "of 2,347 kcal today" — asserting "kcal today" pins the flip AND
        // that the target is now visible on the dashboard (not just inside the readout sheet).
        let goalLine = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "kcal today")).firstMatch
        XCTAssertTrue(goalLine.waitForExistence(timeout: 6), "Energy headline didn't switch to the goal.")
        shot(app, "6b-goal-live")

        // The Today card is the COMPLETE targets reference (2026-07-22): tap the strip and the
        // sheet shows every macro floor AND the sex-aware micro floors — potassium is the canary.
        app.buttons["Fueling readout"].tap()
        XCTAssertTrue(app.navigationBars["Today's fueling"].waitForExistence(timeout: 6),
                      "Today card didn't open from the strip.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "mg potassium"))
            .firstMatch.waitForExistence(timeout: 4), "Micros grid missing from the Today card.")
        shot(app, "6c-today-card-micros")
    }

    /// FUEL is "try-then-paywall" (user decision 2026-07-21; mirrors the AI coach). The free tier
    /// lands on the REAL page — no frost — with a live composer it can focus and TYPE into; the wall
    /// fires only on a Pro ACTION (send, history, goals). This asserts the page is live for a free
    /// athlete, and that both the SEND action and the (now-visible) toolbar entries reach the paywall.
    func testFuelIsProGated() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--debug-free", "--fuel"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Fuel"].waitForExistence(timeout: 20), "Fuel tab missing.")

        // The page renders FULLY for a free athlete — the composer is live and typeable (the "try"),
        // not frosted behind a lock card. Match the vertical-axis TextField by placeholder, as the
        // other tests do.
        let byPlaceholder = NSPredicate(format: "placeholderValue BEGINSWITH %@", "What did you eat?")
        let field = app.descendants(matching: .any).matching(byPlaceholder).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Composer field missing — the free page should be live, not frosted.")
        field.tap()
        // The entry reveal-cascade can swallow the first tap's focus — retap until the keyboard confirms.
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        }
        field.typeText("test meal")
        shot(app, "8-fuel-free-composer")

        // The stable paywall anchor: the annual-default primary CTA. Eligible athletes see the
        // seven-day trial; ineligible returning subscribers see the immediate localized price.
        // Tapping SEND must present it (this contextual paywall remains dismissible).
        let trialCTA = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Continue ·' OR label BEGINSWITH 'Start my'")).firstMatch
        app.buttons["Log meal"].tap()
        XCTAssertTrue(trialCTA.waitForExistence(timeout: 8), "Send didn't present the paywall for a free athlete.")
        shot(app, "8a-fuel-free-paywall")

        // Dismiss the paywall (soft — it carries a Close affordance), then prove a toolbar entry that
        // used to be HIDDEN is now visible and also reaches the wall. firstMatch: more than one
        // "Close" can legitimately coexist in the sheet stack — the topmost is the paywall's.
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Fueling goals"].waitForExistence(timeout: 6),
                      "Fueling goals button should be visible on the free tier (it gates on tap now).")
        XCTAssertTrue(app.buttons["Meal history"].exists,
                      "Meal history button should be visible on the free tier (it gates on tap now).")
        app.buttons["Fueling goals"].tap()
        XCTAssertTrue(trialCTA.waitForExistence(timeout: 8), "Fueling goals didn't reach the paywall for a free athlete.")

        // Meal history is the OTHER now-visible toolbar entry — prove it ALSO reaches the wall, not
        // merely that the button exists. A regression that restored a plain NavigationLink to
        // FuelHistoryView, or set showingHistory = true unconditionally, would leak full history to a
        // free athlete while the .exists check above stayed green; tapping it and asserting the
        // paywall fires is what actually pins the gate.
        app.buttons["Close"].firstMatch.tap()
        app.buttons["Meal history"].tap()
        XCTAssertTrue(trialCTA.waitForExistence(timeout: 8), "Meal history didn't reach the paywall for a free athlete.")

        // The health-score gauge (2026-08-15) is the third gated toolbar door — visible free,
        // walls on tap, exactly like its siblings.
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Health score"].waitForExistence(timeout: 6),
                      "Health score gauge should be visible on the free tier (it gates on tap).")
        app.buttons["Health score"].tap()
        XCTAssertTrue(trialCTA.waitForExistence(timeout: 8), "Health score didn't reach the paywall for a free athlete.")
    }

    /// The health-score surface (2026-08-15): meal rows wear score chips, the masthead gauge
    /// opens the analysis page, and the page carries the day verdict + drivers + ranked food.
    func testHealthScorePage() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--reset-fuel", "--seed-fuel-today",
                               "--debug-pro", "--fuel"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 20), "Fuel page didn't appear.")

        // The seeded day carries quality fields, so rows wear their chips ("Health score N, Band").
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Health score "))
            .firstMatch.waitForExistence(timeout: 8), "Meal rows didn't grow their score chips.")
        shot(app, "11-rows-with-scores")

        // The masthead gauge opens the analysis page: hero verdict, drivers, ranked food, and the
        // month report (retitled "Nutrition" when the trends sections landed, 2026-08-20).
        app.buttons["Health score"].tap()
        XCTAssertTrue(app.navigationBars["Nutrition"].waitForExistence(timeout: 6),
                      "Nutrition page didn't open from the gauge.")
        XCTAssertTrue(app.staticTexts["WHAT SHAPED IT"].waitForExistence(timeout: 6),
                      "Drivers section missing from the health page.")
        XCTAssertTrue(app.staticTexts["TODAY'S FOOD, RANKED"].waitForExistence(timeout: 4),
                      "Ranked-food section missing from the health page.")
        // The 7-day capsule strip became the 30-day score chart when the page grew into the
        // month report (2026-08-20) — NutritionReportUITests walks the full page; this smoke
        // just confirms the trend chapter begins. Below the fold now (ranked rows precede it),
        // and off-viewport rows leave the AX tree — swipe to it (the HealthDetail gotcha).
        var swipes = 0
        while !app.staticTexts["THE LAST 30 DAYS"].exists, swipes < 6 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(app.staticTexts["THE LAST 30 DAYS"].exists, "Trend section missing.")
        shot(app, "11a-health-page")
    }

    /// Local-first resolution (FUEL-FLOW §1.5): re-typing a meal the athlete has logged before —
    /// even PHRASED DIFFERENTLY — resolves instantly from their own history, with no network round
    /// trip. The seed contains "2 eggs, toast, coffee" (28 g carbs / 350 kcal / 18 g protein);
    /// typing the reworded "2 eggs and toast with coffee" must land those EXACT seeded numbers.
    ///
    /// Why that's airtight even against a reachable backend: the estimator could never return that
    /// exact multi-field tuple for reworded words, and — the behavioral proof — an estimating row
    /// deliberately does not open its edit sheet, so a row that opens on the first tap was never on
    /// the network path. Content match + immediate interactivity together mean the numbers came
    /// from the local copy, not the model.
    func testLocalFirstResolvesRewordedMeal() {
        let app = XCUIApplication()
        // Seed the athlete's history (yesterday-and-back; today stays empty), unlock Pro, land on Fuel.
        app.launchArguments = ["--reset-store", "--seed-demo", "--reset-fuel", "--seed-fuel-history", "--debug-pro", "--fuel"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 20), "Fuel page didn't appear.")

        // Type a REWORDING of the seeded "2 eggs, toast, coffee". The normalizer collapses joiner
        // words ("and", "with") and comma boundaries to the same key.
        let byPlaceholder = NSPredicate(format: "placeholderValue BEGINSWITH %@", "What did you eat?")
        let field = app.descendants(matching: .any).matching(byPlaceholder).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Composer field not found.")
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        }
        field.typeText("2 eggs and toast with coffee")
        app.buttons["Log meal"].tap()

        // The row's numbers line must carry the EXACT seeded tuple — the "g carbs ·" separator
        // distinguishes it from the readout strip's "≈28 of 350 g carbs". A network estimate for
        // reworded words could not reproduce this, and it appears without an estimating beat.
        let seededNumbers = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "≈28 g carbs · 350 kcal · 18 g protein")).firstMatch
        XCTAssertTrue(seededNumbers.waitForExistence(timeout: 6),
                      "Reworded meal didn't resolve to the exact seeded numbers — local lookup missed.")
        shot(app, "9-local-first-instant")

        // Behavioral proof it never estimated: an estimating row ignores taps; this one opens the
        // edit sheet on the first tap.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "2 eggs and toast")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "Logged row not found.")
        row.tap()
        XCTAssertTrue(app.navigationBars["Meal"].waitForExistence(timeout: 5),
                      "Row didn't open its sheet on first tap — it was still estimating, not a local hit.")
        shot(app, "9a-local-first-editable")
    }

    /// Rung two of the resolution ladder (FUEL-FLOW §2): every food phrase is a staple, so the
    /// meal composes deterministically — exact table numbers, instantly, zero network, on day one
    /// with no history. Also pins the starters handoff: quick-log chips before any usuals exist,
    /// the athlete's own usuals the moment they do.
    func testStaplesComposeInstantly() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--reset-fuel", "--fuel"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Fuel"].waitForExistence(timeout: 20), "Fuel page didn't appear.")

        // Day one: no usuals yet, so the staples starters offer the first tap.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Quick log:"))
            .firstMatch.waitForExistence(timeout: 6), "Starter chips missing on an empty journal.")
        shot(app, "10-starter-chips")

        let byPlaceholder = NSPredicate(format: "placeholderValue BEGINSWITH %@", "What did you eat?")
        let field = app.descendants(matching: .any).matching(byPlaceholder).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Composer field not found.")
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        }
        field.typeText("2 gels and a banana")
        app.buttons["Log meal"].tap()

        // The exact table totals land at once — 2×gel (100 kcal / 23 g) + banana (105 / 27) —
        // with no estimating beat: this send never touched the network.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "≈73 g carbs · 305 kcal"))
            .firstMatch.waitForExistence(timeout: 5), "Staple compose didn't land the table numbers.")
        shot(app, "10a-staples-composed")

        // Composed rows are never "estimating", so the editor opens on the FIRST tap — and in
        // items mode (portion steppers), because the compose produced a real breakdown.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "2 gels and a banana")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "Composed row not found.")
        row.tap()
        XCTAssertTrue(app.navigationBars["Meal"].waitForExistence(timeout: 5), "Editor didn't open on first tap.")
        XCTAssertTrue(app.buttons["Set totals by hand"].waitForExistence(timeout: 3),
                      "Composed meal should open in items mode.")
        // The full story (2026-08-15): a composed meal's sheet carries its live health gauge.
        XCTAssertTrue(app.staticTexts["HEALTH SCORE"].waitForExistence(timeout: 4),
                      "Items sheet should lead with the health-score hero.")
        shot(app, "10b-items-sheet")
        app.buttons["Cancel"].tap()

        // The meal has numbers now, so the row hands over from starters to the athlete's usuals.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Log again:"))
            .firstMatch.waitForExistence(timeout: 5), "Usuals didn't take over from starters.")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
