import Testing
import Foundation
@testable import Momentum

/// FuelReadiness — the fueling judge (FUEL pillar). Pins the g/kg bands, the day-paced status
/// curve, the driving-session selection (biggest session in today+tomorrow), the energy/sodium
/// floors, and the refuel window. Floors, never ceilings.
struct FuelReadinessTests {
    let cal = Calendar.current
    /// A fixed mid-afternoon anchor (15:00) — dayFraction (06→22h) = 9/16 ≈ 0.5625.
    var now: Date { cal.date(bySettingHour: 15, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_760_000_000))! }

    func meal(_ hoursAgo: Double, kcal: Int? = nil, carbs: Int? = nil,
              protein: Int? = nil, sodium: Int? = nil) -> FuelReadiness.MealInput {
        .init(eatenAt: now.addingTimeInterval(-hoursAgo * 3600), kcal: kcal, carbsG: carbs,
              proteinG: protein, sodiumMg: sodium)
    }

    @Test func easyDayUsesBaseCarbBand() {
        let r = FuelReadiness.readout(meals: [], sessions: [], workoutsToday: [],
                                      bodyMassKg: 70, now: now)
        #expect(r.carbsFloorG == 210)            // 3 g/kg × 70
        #expect(r.carbsHighG == 350)             // (3+2) g/kg × 70
        #expect(r.kcalFloor == 2100)             // 30 kcal/kg, no training
        #expect(r.proteinFloorG == 98)           // 1.4 g/kg
        #expect(r.sodiumFloorMg == 1500)         // baseline only
        #expect(r.status == .empty)
        #expect(r.drivingSession == nil)
    }

    @Test func tomorrowsLongRunDrivesTheCarbTarget() {
        let tomorrow = FuelReadiness.SessionInput(date: now.addingTimeInterval(86_400),
                                                  durationS: 2.6 * 3600, isRace: false)
        let r = FuelReadiness.readout(meals: [meal(2, carbs: 100)], sessions: [tomorrow],
                                      workoutsToday: [], bodyMassKg: 70, now: now)
        #expect(r.carbsFloorG == 420)            // 6 g/kg long tier
        #expect(r.drivingSession?.contains("tomorrow") == true)
        #expect(r.drivingSession?.contains("long") == true)
    }

    @Test func raceEveGetsTheClassicLoad() {
        let race = FuelReadiness.SessionInput(date: now.addingTimeInterval(86_400),
                                              durationS: 3 * 3600, isRace: true)
        let r = FuelReadiness.readout(meals: [], sessions: [race], workoutsToday: [],
                                      bodyMassKg: 70, now: now)
        #expect(r.carbsFloorG == 560)            // 8 g/kg race-eve
        #expect(r.drivingSession?.contains("race") == true)
    }

    @Test func statusPacesAcrossTheDay() {
        let session = FuelReadiness.SessionInput(date: now, durationS: 1.5 * 3600, isRace: false)
        // Floor = 5 g/kg × 70 = 350. At 15:00 dayFraction ≈ 0.5625 → expected ≈ 197; 0.8× ≈ 157.
        let onTrack = FuelReadiness.readout(meals: [meal(1, carbs: 170)], sessions: [session],
                                            workoutsToday: [], bodyMassKg: 70, now: now)
        #expect(onTrack.status == .onTrack)
        let behind = FuelReadiness.readout(meals: [meal(1, carbs: 80)], sessions: [session],
                                           workoutsToday: [], bodyMassKg: 70, now: now)
        #expect(behind.status == .behind)
        let fueled = FuelReadiness.readout(meals: [meal(1, carbs: 360)], sessions: [session],
                                           workoutsToday: [], bodyMassKg: 70, now: now)
        #expect(fueled.status == .fueled)
    }

    @Test func trainingRaisesEnergyAndSodiumFloors() {
        let long = FuelReadiness.WorkoutInput(endedAt: now.addingTimeInterval(-3 * 3600),
                                              durationS: 2 * 3600, kcal: 1400)
        let r = FuelReadiness.readout(meals: [meal(0.2, carbs: 50)], sessions: [],
                                      workoutsToday: [long], bodyMassKg: 70, now: now)
        #expect(r.kcalFloor == 2100 + 1400)               // baseline + the day's burn
        #expect(r.sodiumFloorMg == 1500 + 700)            // +700 mg per long hour beyond the first
    }

    @Test func refuelWindowFlagsUntilTheNextMeal() {
        let finished = FuelReadiness.WorkoutInput(endedAt: now.addingTimeInterval(-30 * 60),
                                                  durationS: 1.2 * 3600, kcal: 800)
        let due = FuelReadiness.readout(meals: [meal(3, carbs: 120)], sessions: [],
                                        workoutsToday: [finished], bodyMassKg: 70, now: now)
        #expect(due.refuelDue)                            // ended 30 min ago, nothing eaten since
        #expect(due.headline.contains("Refuel"))
        let fed = FuelReadiness.readout(meals: [meal(3, carbs: 120), meal(0.1, carbs: 60)],
                                        sessions: [], workoutsToday: [finished],
                                        bodyMassKg: 70, now: now)
        #expect(!fed.refuelDue)                           // a meal after the finish clears it
    }

    @Test func pendingMealsCountButDoNotTotal() {
        let pending = FuelReadiness.MealInput(eatenAt: now.addingTimeInterval(-600),
                                              kcal: nil, carbsG: nil, proteinG: nil, sodiumMg: nil)
        let r = FuelReadiness.readout(meals: [meal(2, carbs: 90, sodium: 400), pending],
                                      sessions: [], workoutsToday: [], bodyMassKg: 70, now: now)
        #expect(r.carbsG == 90)
        #expect(r.sodiumMg == 400)
        #expect(r.mealCount == 2)
        #expect(r.pendingCount == 1)
        #expect(r.status != .empty)                       // logged meals mean the day has begun
    }

    @Test func missingBodyMassFallsBackToSeventyKg() {
        let r = FuelReadiness.readout(meals: [], sessions: [], workoutsToday: [],
                                      bodyMassKg: nil, now: now)
        #expect(r.carbsFloorG == 210)
        #expect(r.kcalFloor == 2100)
    }
}
