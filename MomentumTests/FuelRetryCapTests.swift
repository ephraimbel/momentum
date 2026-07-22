import Testing
import Foundation
@testable import Momentum

/// The bounded-retry contract (FUEL): a meal the estimator can't parse must stop costing API
/// calls, and a hand-set meal must never be re-estimated at all.
/// `@MainActor` because `FuelLocalResolver` is main-actor isolated (it is the SwiftData glue).
@Suite("FuelRetryCap")
@MainActor
struct FuelRetryCapTests {
    private func pending(attempts: Int) -> Meal {
        let m = Meal()
        m.text = "something the model can't read"
        m.estimateAttempts = attempts
        return m
    }

    @Test func freshPendingMealIsDue() {
        #expect(pending(attempts: 0).needsEstimate(maxAttempts: 3))
    }

    @Test func attemptsBelowTheCapStayDue() {
        #expect(pending(attempts: 1).needsEstimate(maxAttempts: 3))
        #expect(pending(attempts: 2).needsEstimate(maxAttempts: 3))
    }

    @Test func atTheCapItRests() {
        #expect(!pending(attempts: 3).needsEstimate(maxAttempts: 3))
        #expect(!pending(attempts: 9).needsEstimate(maxAttempts: 3))   // never drifts back into due
    }

    @Test func aMealWithNumbersIsNeverDue() {
        let m = pending(attempts: 0)
        m.carbsG = 60
        #expect(!m.needsEstimate(maxAttempts: 3))
    }

    @Test func manualAlwaysOutranksTheEstimator() {
        let m = pending(attempts: 0)
        m.source = "manual"
        #expect(!m.needsEstimate(maxAttempts: 3))
    }

    // MARK: - `isEstimable` — the one gate both firing paths ask

    /// The hand-fired "Estimate again" ignores the CAP (the limit is the app's, not the athlete's)
    /// but must obey everything else `needsEstimate` obeys. It used to check only `carbsG == nil`,
    /// so it offered a billed call on a hand-set meal — which `FuelEstimator.apply` discards on
    /// arrival, leaving the row unchanged and the button still showing. Repeatable, and chargeable
    /// every time. One predicate, so the two can't drift apart again.
    @Test func estimatingAHandSetMealCanNeverBeOffered() {
        let m = pending(attempts: 0)
        m.source = "manual"          // hand-set…
        #expect(m.carbsG == nil)     // …but carbs left blank: the state the old check missed
        #expect(!m.isEstimable)
        #expect(!m.needsEstimate(maxAttempts: 3))
    }

    /// Capped but still genuinely estimable: the automatic loop rests, the athlete's own request
    /// still runs. That gap between the two predicates is the whole point of the menu item.
    @Test func theCapStopsTheLoopNotTheAthlete() {
        let m = pending(attempts: 3)
        #expect(!m.needsEstimate(maxAttempts: 3))
        #expect(m.isEstimable)
    }

    /// An `ai` meal that came back with no items has numbers of nil and a source of "ai": the
    /// automatic loop won't touch it (not `pending`), but `apply` would still work on it, so
    /// asking by hand is legitimate.
    @Test func anEmptyAIResultStaysEstimableByHand() {
        let m = pending(attempts: 1)
        m.source = "ai"
        #expect(m.isEstimable)
        #expect(!m.needsEstimate(maxAttempts: 3))
    }

    @Test func aMealWithNumbersIsNotEstimable() {
        let m = pending(attempts: 0)
        m.carbsG = 60
        #expect(!m.isEstimable)
    }

    /// A locally-resolved meal (copied from the athlete's own history) is `ai`/`manual` with real
    /// numbers, so the retry path can never fire for it — no new field, no bookkeeping.
    @Test func aLocallyResolvedMealIsNeverDue() {
        let source = Meal()
        source.text = "2 eggs, toast, coffee"
        source.carbsG = 42
        source.kcal = 380
        source.source = "ai"
        let copy = Meal()
        copy.text = source.text
        FuelLocalResolver.copyNumbers(from: source, to: copy)
        #expect(!copy.needsEstimate(maxAttempts: 3))
        #expect(copy.source == "ai")
        #expect(copy.carbsG == 42)
    }

    /// `copyNumbers` deliberately leaves the old coach note behind — it narrated a different day's
    /// session, and carrying it forward would be a fabricated claim.
    @Test func theOldCoachNoteNeverCrossesADay() {
        let source = Meal()
        source.text = "big pasta dinner"
        source.carbsG = 120
        source.source = "ai"
        source.note = "Good carb bank for tomorrow's long run."
        let copy = Meal()
        copy.text = source.text
        FuelLocalResolver.copyNumbers(from: source, to: copy)
        #expect(copy.note == nil)
        #expect(copy.carbsG == 120)
    }

    @Test func aFreshMealStartsWithNoAttempts() {
        #expect(Meal().estimateAttempts == 0)   // lightweight-migration default
    }

    // MARK: - Only a call that was actually made may spend an attempt

    /// The journal takes the attempt at fire time and hands it back when the estimator reports the
    /// request never left the device. Without that refund, logging in airplane mode and switching
    /// tabs twice exhausted a meal's whole budget on calls that were never made — and landing
    /// never brought the estimate back.
    @Test func offlineErrorsProveTheFunctionWasNeverReached() {
        for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost,
                                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                                    .dataNotAllowed, .internationalRoamingOff,
                                    .secureConnectionFailed] {
            #expect(FuelEstimator.neverReachedServer(URLError(code)), "\(code) should be free")
        }
    }

    /// A timeout deliberately DOES count: the bytes went out, the model may be running right now,
    /// and a meal that times out on every visit is the standing tax the cap exists to stop.
    @Test func aTimeoutStillCostsAnAttempt() {
        #expect(!FuelEstimator.neverReachedServer(URLError(.timedOut)))
        #expect(!FuelEstimator.neverReachedServer(URLError(.badServerResponse)))
    }

    /// Unrecognized failures fail toward BOUNDING cost, never toward a meal that re-fires forever.
    @Test func anUnknownFailureIsNotAssumedFree() {
        struct Mystery: Error {}
        #expect(!FuelEstimator.neverReachedServer(Mystery()))
    }

    // MARK: - Micros stay nil-preserving

    private func item(name: String, kcal: Int, carbs: Int, potassium: Int? = nil,
                      iron: Double? = nil) -> MealItem {
        MealItem(name: name, qty: 1, unit: "serving", kcal: kcal, carbsG: carbs,
                 proteinG: 0, fatG: 0, sodiumMg: 0, fluidsMl: 0,
                 potassiumMg: potassium, magnesiumMg: nil, ironMg: iron, calciumMg: nil)
    }

    /// Since the estimator stopped returning micros (2026-07-21) every item carries nil, and the
    /// meal total must stay nil rather than collapsing to a confident 0 — a 0 would read as a
    /// measured zero to any future micro surface instead of "never estimated".
    @Test func allNilMicrosSumToNilNotZero() {
        let m = Meal()
        m.applyTotals(from: [item(name: "Toast", kcal: 90, carbs: 17),
                             item(name: "Coffee", kcal: 5, carbs: 1)])
        #expect(m.potassiumMg == nil)
        #expect(m.magnesiumMg == nil)
        #expect(m.ironMg == nil)
        #expect(m.calciumMg == nil)
        #expect(m.kcal == 95)        // the macros still sum normally
        #expect(m.carbsG == 18)
    }

    /// Historical meals that DO carry micros must still total correctly — the nil-preservation
    /// must not cost us the real sums already in the store.
    @Test func realMicrosStillSum() {
        let m = Meal()
        m.applyTotals(from: [item(name: "Spinach", kcal: 20, carbs: 3, potassium: 500, iron: 2.5),
                             item(name: "Lentils", kcal: 200, carbs: 35, potassium: 700, iron: 3.5)])
        #expect(m.potassiumMg == 1200)
        #expect(m.ironMg == 6.0)
        #expect(m.magnesiumMg == nil)   // still absent, still nil
    }

    /// A partial set sums only what exists — one item carrying iron is real data, not a zero.
    @Test func partialMicrosSumWhatExists() {
        let m = Meal()
        m.applyTotals(from: [item(name: "Steak", kcal: 400, carbs: 0, iron: 3.0),
                             item(name: "Rice", kcal: 200, carbs: 45)])
        #expect(m.ironMg == 3.0)
        #expect(m.potassiumMg == nil)
    }
}
