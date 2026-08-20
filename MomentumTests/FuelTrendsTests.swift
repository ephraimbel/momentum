import Testing
import Foundation
@testable import Momentum

/// Pins the monthly nutrition-report engine (2026-08-20): day bucketing with honest gaps, floor
/// consistency counted in DAYS MET (floors doctrine), kcal-weighted weekly quality shares that
/// sum to one, recurrence-ranked foods, and the mineral month with its 5-logged-day gate.
struct FuelTrendsTests {

    private let cal = Calendar.current
    /// A fixed "now" mid-afternoon so day bucketing never straddles midnight in CI.
    private var now: Date { cal.date(bySettingHour: 15, minute: 0, second: 0, of: Date())! }

    private func daysAgo(_ n: Int, hour: Int = 12) -> Date {
        cal.date(bySettingHour: hour, minute: 0, second: 0,
                 of: cal.date(byAdding: .day, value: -n, to: now)!)!
    }

    private func facts(_ name: String, kcal: Int, carbs: Int = 0, protein: Int = 0,
                       fiber: Int? = nil, sugar: Int? = nil, nova: Int? = nil) -> HealthScore.Facts {
        HealthScore.Facts(name: name, kcal: kcal, carbsG: carbs, proteinG: protein, fatG: 0,
                          sodiumMg: 0, fiberG: fiber, sugarG: sugar, satFatG: nil,
                          potassiumMg: nil, nova: nova)
    }

    private func meal(_ daysBack: Int, kcal: Int, carbs: Int = 0, protein: Int = 0,
                      facts: [HealthScore.Facts] = [], potassium: Int? = nil,
                      iron: Double? = nil) -> FuelTrends.MealInput {
        FuelTrends.MealInput(eatenAt: daysAgo(daysBack), kcal: kcal, carbsG: carbs,
                             proteinG: protein, facts: facts, potassiumMg: potassium,
                             magnesiumMg: nil, ironMg: iron, calciumMg: nil)
    }

    @Test func emptyWindowProducesNoReport() {
        #expect(FuelTrends.report(meals: [], bodyMassKg: 70, isMale: nil, now: now) == nil)
        // A meal outside the window is the same as no meal.
        let stale = [meal(45, kcal: 800)]
        #expect(FuelTrends.report(meals: stale, bodyMassKg: 70, isMale: nil, now: now) == nil)
    }

    @Test func daysKeepHonestGapsAndAveragesSkipThem() {
        let meals = [meal(0, kcal: 2000, carbs: 250), meal(2, kcal: 1000, carbs: 100)]
        let r = FuelTrends.report(meals: meals, bodyMassKg: 70, isMale: nil, now: now)!
        #expect(r.days.count == 30)
        #expect(r.days.last?.logged == true)
        #expect(r.days[r.days.count - 2].logged == false)   // yesterday: nothing logged
        #expect(r.loggedDays == 2)
        #expect(r.avgKcal == 1500)                           // over logged days only, never ÷30
    }

    @Test func floorConsistencyCountsDaysMet() {
        // 70 kg → carbs floor 210 g, protein floor 98 g.
        let meals = [
            meal(0, kcal: 2000, carbs: 250, protein: 60),    // carbs met, protein not
            meal(1, kcal: 2000, carbs: 100, protein: 120),   // protein met, carbs not
            meal(2, kcal: 2000, carbs: 300, protein: 100),   // both met
        ]
        let r = FuelTrends.report(meals: meals, bodyMassKg: 70, isMale: nil, now: now)!
        #expect(r.carbsFloorG == 210)
        #expect(r.proteinFloorG == 98)
        #expect(r.carbsDaysMet == 2)
        #expect(r.proteinDaysMet == 2)
    }

    @Test func weeklySharesAreKcalWeightedAndSumToOne() {
        // One week: 800 kcal of whole food vs 200 kcal of processed — shares weight by energy.
        let whole = facts("Lentil stew", kcal: 800, carbs: 90, protein: 40, fiber: 15, nova: 1)
        let junk = facts("Candy", kcal: 200, carbs: 50, sugar: 45, nova: 4)
        let meals = [meal(1, kcal: 800, facts: [whole]), meal(1, kcal: 200, facts: [junk])]
        let r = FuelTrends.report(meals: meals, bodyMassKg: 70, isMale: nil, now: now)!
        #expect(r.weeks.count >= 1)
        let mix = r.weeks.last!
        let total = mix.share.values.reduce(0, +)
        #expect(abs(total - 1) < 0.0001)
        #expect(r.novaSampled == true)   // items carried NOVA → composition claims are valid
        // The whole food carries ~4× the energy — its band must dominate the week.
        let wholeShare = mix.share[.whole] ?? 0
        #expect(wholeShare > 0.6)
        #expect(mix.processedShare > 0)
        #expect(wholeShare > mix.processedShare)
    }

    @Test func topFoodsRankByRecurrence() {
        let oats = facts("Oatmeal", kcal: 400, carbs: 60, fiber: 6, nova: 1)
        let cookie = facts("Cookie", kcal: 900, sugar: 30, nova: 4)
        let meals = [
            meal(0, kcal: 400, facts: [oats]),
            meal(1, kcal: 400, facts: [oats]),
            meal(2, kcal: 400, facts: [oats]),
            meal(3, kcal: 900, facts: [cookie]),
        ]
        let r = FuelTrends.report(meals: meals, bodyMassKg: 70, isMale: nil, now: now)!
        #expect(r.topFoods.first?.name == "Oatmeal")         // 3 appearances beat 900 kcal
        #expect(r.topFoods.first?.count == 3)
        #expect(r.topFoods.count == 2)
        // Meals carrying NO facts (pending estimates, no numbers) never rank — there's no name
        // to count. (Totals-only meals DO rank by their sentence via the pseudo-fact, the same
        // precedent the usuals chips set.)
        let factless = [meal(0, kcal: 600), meal(1, kcal: 600), meal(2, kcal: 600),
                        meal(3, kcal: 600), meal(4, kcal: 600)]
        let r2 = FuelTrends.report(meals: factless, bodyMassKg: 70, isMale: nil, now: now)!
        #expect(r2.topFoods.isEmpty)
        #expect(r2.novaSampled == false)   // no NOVA anywhere → processed-share stays unclaimed
    }

    @Test func microMonthGatesOnFiveLoggedDays() {
        let four = (0..<4).map { meal($0, kcal: 2000, potassium: 3000, iron: 10) }
        let r4 = FuelTrends.report(meals: four, bodyMassKg: 70, isMale: nil, now: now)!
        #expect(r4.micros == nil)

        let five = (0..<5).map { meal($0, kcal: 2000, potassium: 3000, iron: 10) }
        let r5 = FuelTrends.report(meals: five, bodyMassKg: 70, isMale: nil, now: now)!
        #expect(r5.micros != nil)
        #expect(abs((r5.micros?.potassium.avg ?? 0) - 3000) < 0.001)
    }

    @Test func microFloorsAreSexAwareAndInsightNamesTheWidestSampledGap() {
        // Magnesium/calcium were never estimated: unknown, NOT zero — an unsampled micro must
        // never drive the insight (else every pre-micros meal history reads "Magnesium averaged
        // 0 mg"). Iron IS sampled and under floor, so it's the one named for both sexes.
        let meals = (0..<6).map { meal($0, kcal: 2000, potassium: 3000, iron: 6) }
        let female = FuelTrends.report(meals: meals, bodyMassKg: 70, isMale: false, now: now)!
        #expect(female.micros?.iron.floor == 18)             // sex-aware floor
        #expect(female.micros?.magnesium.sampled == false)
        #expect(female.micros?.insight?.contains("Iron") == true)
        let male = FuelTrends.report(meals: meals, bodyMassKg: 70, isMale: true, now: now)!
        #expect(male.micros?.iron.floor == 8)
        #expect(male.micros?.insight?.contains("Iron") == true)
    }

    @Test func insightStaysSilentWhenTheMonthLooksAfterItself() {
        let lines = [
            FuelTrends.MicroMonth.Line(label: "Potassium", avg: 3200, floor: 3000, unit: "mg", sampled: true),
            FuelTrends.MicroMonth.Line(label: "Iron", avg: 12, floor: 13, unit: "mg", sampled: true),   // 92%
            // A never-estimated micro is silent too — unknown is not a gap.
            FuelTrends.MicroMonth.Line(label: "Magnesium", avg: 0, floor: 370, unit: "mg", sampled: false),
        ]
        #expect(FuelTrends.microInsight(lines) == nil)
    }

    @Test func mealsLaterTodayStillCountToday() {
        // A pre-logged dinner (or a demo day read just after midnight) sits later than `now` on
        // the clock but belongs to today's bucket — the `<= now` guard that once dropped it
        // nil'd the whole report at 00:48 with a fully seeded day (caught live 2026-08-20).
        let dinner = FuelTrends.MealInput(eatenAt: now.addingTimeInterval(5 * 3600), kcal: 700,
                                          carbsG: 80, proteinG: 40, facts: [],
                                          potassiumMg: nil, magnesiumMg: nil, ironMg: nil, calciumMg: nil)
        let r = FuelTrends.report(meals: [dinner], bodyMassKg: 70, isMale: nil, now: now)
        #expect(r != nil)
        #expect(r?.days.last?.kcal == 700)
    }

    @Test func scoreAveragesOnlyScoredDays() {
        let scored = meal(0, kcal: 500, facts: [facts("Apple", kcal: 100, carbs: 25, fiber: 4, nova: 1)])
        let totalsOnly = meal(1, kcal: 700)   // no facts → no score for the day
        let r = FuelTrends.report(meals: [scored, totalsOnly], bodyMassKg: 70, isMale: nil, now: now)!
        #expect(r.days.last?.score != nil)
        #expect(r.days[r.days.count - 2].score == nil)
        #expect(r.avgScore == r.days.last?.score)
    }
}
