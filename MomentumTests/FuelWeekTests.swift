import Foundation
import Testing
@testable import Momentum

/// Pins the week-consistency engine and the hydration floor (2026-08-15) — the two additions
/// that turned the readout from a single day into a tracker with a memory.
struct FuelWeekTests {

    private let cal = Calendar.current
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12))! }
    private func day(_ back: Int, hour: Int = 9) -> Date {
        cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: now))!.addingTimeInterval(Double(hour) * 3600)
    }
    /// 70 kg fallback → easy carb floor 210 g, protein floor 98 g.
    private func meal(_ back: Int, carbs: Int?, protein: Int? = nil) -> FuelWeek.MealInput {
        FuelWeek.MealInput(eatenAt: day(back), carbsG: carbs, proteinG: protein)
    }

    @Test func sevenCellsOldestToToday() {
        let s = FuelWeek.summary(meals: [], bodyMassKg: nil, now: now, calendar: cal)
        #expect(s.cells.count == 7)
        #expect(s.cells.last?.isToday == true)
        #expect(s.cells.first!.day < s.cells.last!.day)
        #expect(s.loggedCount == 0)
        #expect(s.line == nil)   // an empty journal owes no verdict
    }

    @Test func floorsJudgePerDayAndSumWithinTheDay() {
        // Day-2 hits the carb floor across TWO meals; day-1 logs but misses; today hits protein.
        let meals = [meal(2, carbs: 120), meal(2, carbs: 95),
                     meal(1, carbs: 40),
                     meal(0, carbs: 30, protein: 100)]
        let s = FuelWeek.summary(meals: meals, bodyMassKg: 70, now: now, calendar: cal)
        #expect(s.loggedCount == 3)
        #expect(s.carbsMetCount == 1)
        #expect(s.proteinMetCount == 1)
        #expect(s.cells[4].carbsMet)          // day-2 (index: 6-back)
        #expect(s.cells[5].logged && !s.cells[5].carbsMet)
        #expect(s.line == "Carb floor met 1 of the last 7 days · protein 1 of 7.")
    }

    @Test func silentUnderThreeLoggedDays() {
        let s = FuelWeek.summary(meals: [meal(0, carbs: 300), meal(1, carbs: 300)],
                                 bodyMassKg: 70, now: now, calendar: cal)
        #expect(s.line == nil)
        #expect(s.carbsMetCount == 2)   // the dots still tell the truth
    }

    @Test func windowExcludesOlderAndFutureLeaningDays() {
        let s = FuelWeek.summary(meals: [meal(7, carbs: 400), meal(6, carbs: 400)],
                                 bodyMassKg: 70, now: now, calendar: cal)
        #expect(s.loggedCount == 1)     // 7 days back is outside a 7-cell window ending today
        #expect(s.cells.first?.carbsMet == true)
    }
}

/// The hydration floor rides `FuelReadiness` — baseline + sweat from hour zero.
struct FuelFluidsTests {

    private func mealNow(fluids: Int?) -> FuelReadiness.MealInput {
        FuelReadiness.MealInput(eatenAt: Date(), kcal: 500, carbsG: 60, proteinG: 20,
                                sodiumMg: 300, fluidsMl: fluids)
    }

    @Test func baselineFloorOnARestDay() {
        let r = FuelReadiness.readout(meals: [mealNow(fluids: 750)], sessions: [],
                                      workoutsToday: [], bodyMassKg: 70, now: Date())
        #expect(r.fluidsFloorMl == FuelReadiness.fluidsBaselineMl)
        #expect(r.fluidsMl == 750)
    }

    @Test func trainingRaisesTheFloorFromHourZero() {
        // A 90-minute finished run: +500 ml/h × 1.5 h — sweat starts at hour zero, unlike the
        // sodium add-on's first-hour grace.
        let w = FuelReadiness.WorkoutInput(endedAt: Date(), durationS: 5400, kcal: 700)
        let r = FuelReadiness.readout(meals: [], sessions: [], workoutsToday: [w],
                                      bodyMassKg: 70, now: Date())
        #expect(r.fluidsFloorMl == FuelReadiness.fluidsBaselineMl + 750)
    }

    @Test func nilFluidsSumHonestly() {
        let r = FuelReadiness.readout(meals: [mealNow(fluids: nil), mealNow(fluids: 250)],
                                      sessions: [], workoutsToday: [], bodyMassKg: 70, now: Date())
        #expect(r.fluidsMl == 250)
    }

    @Test func goalNeverOverridesHydration() {
        // Drinking is never part of a deficit — leaner/custom leave the floor alone.
        var goal = FuelReadiness.GoalInput(); goal.kind = .leaner
        let r = FuelReadiness.readout(meals: [], sessions: [], workoutsToday: [],
                                      bodyMassKg: 70, goal: goal, now: Date())
        #expect(r.fluidsFloorMl == FuelReadiness.fluidsBaselineMl)
    }
}
