import Testing
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
