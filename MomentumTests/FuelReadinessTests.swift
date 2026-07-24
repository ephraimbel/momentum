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
              protein: Int? = nil, fat: Int? = nil, sodium: Int? = nil) -> FuelReadiness.MealInput {
        .init(eatenAt: now.addingTimeInterval(-hoursAgo * 3600), kcal: kcal, carbsG: carbs,
              proteinG: protein, fatG: fat, sodiumMg: sodium)
    }

    @Test func fatFloorIsOneGramPerKgAndSums() {
        // kcal present so the meals count as numbered (hasNumbers keys off carbs/kcal).
        let r = FuelReadiness.readout(meals: [meal(3, kcal: 300, fat: 22), meal(1, kcal: 250, fat: 18)],
                                      sessions: [], workoutsToday: [], bodyMassKg: 70, now: now)
        #expect(r.fatFloorG == 70)               // 1 g/kg — the hormonal-health minimum
        #expect(r.fatG == 40)
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

    @Test func muscleGoalsLeadWithProteinNotCarbs() {
        // Plan-fueling is carb-first (carbs power the session); muscle goals (leaner/build/custom)
        // are protein-first. The status bar + headline must judge the LEADING macro.
        // proteinFloor(leaner) = 1.9 g/kg × 70 = 133.
        let leaner = goal(.leaner)

        // Protein floor met, carbs almost nothing → FUELED. A carb-led judge would say "behind".
        let proteinMet = FuelReadiness.readout(meals: [meal(1, carbs: 20, protein: 140)],
                                               sessions: [], workoutsToday: [],
                                               bodyMassKg: 70, goal: leaner, now: now)
        #expect(proteinMet.primary == .protein)
        #expect(proteinMet.primaryValueG == 140 && proteinMet.primaryFloorG == 133)
        #expect(proteinMet.status == .fueled)
        #expect(proteinMet.headline.lowercased().contains("protein"))

        // Carbs sky-high but protein low → NOT fueled: on a muscle goal carbs don't drive the bar.
        let carbsHighProteinLow = FuelReadiness.readout(meals: [meal(1, carbs: 400, protein: 10)],
                                                        sessions: [], workoutsToday: [],
                                                        bodyMassKg: 70, goal: leaner, now: now)
        #expect(carbsHighProteinLow.status != .fueled)

        // build also leads with protein; plan-fueling (the default) still leads with carbs.
        let build = FuelReadiness.readout(meals: [meal(1, protein: 20)], sessions: [],
                                          workoutsToday: [], bodyMassKg: 70, goal: goal(.build), now: now)
        #expect(build.primary == .protein)
        let plan = FuelReadiness.readout(meals: [meal(1, carbs: 400, protein: 10)],
                                         sessions: [], workoutsToday: [], bodyMassKg: 70, now: now)
        #expect(plan.primary == .carbs)
        #expect(plan.status == .fueled)   // carbs well past the floor
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

    // MARK: The fueling adjuster (goal math — Mifflin-St Jeor × 1.35 daily base + real burn)

    /// 70 kg / 172 cm / male, `now` is 2025 → age 35 → BMR 1605, maintenance ≈ 2167.
    private func goal(_ kind: FuelReadiness.GoalInput.Kind,
                      customKcal: Int? = nil, customCarbs: Int? = nil) -> FuelReadiness.GoalInput {
        .init(kind: kind, heightCm: 172,
              birthYear: Calendar.current.component(.year, from: now) - 35, isMale: true,
              customKcal: customKcal, customCarbsG: customCarbs)
    }

    @Test func leanerRunsAGentleDeficitWithHigherProtein() {
        let r = FuelReadiness.readout(meals: [], sessions: [], workoutsToday: [],
                                      bodyMassKg: 70, goal: goal(.leaner), now: now)
        #expect(r.kcalFloor == 1767)              // max(2167 − 400, 1605 × 1.1) — the guard binds
        #expect(r.kcalIsGoal)
        #expect(r.proteinFloorG == 133)           // 1.9 g/kg protects muscle in a deficit
        #expect(r.goalNote == nil)
    }

    @Test func deficitPausesWhenTheTrainingTalks() {
        let race = FuelReadiness.SessionInput(date: now.addingTimeInterval(86_400),
                                              durationS: 3 * 3600, isRace: true)
        let r = FuelReadiness.readout(meals: [], sessions: [race], workoutsToday: [],
                                      bodyMassKg: 70, goal: goal(.leaner), now: now)
        #expect(r.kcalFloor == 2167)              // full maintenance — no deficit on race eve
        #expect(r.goalNote != nil)
        #expect(r.carbsFloorG == 560)             // the classic load is untouched
    }

    @Test func leanerEasesCarbsOnLighterDays() {
        // The goal tunes the tier (2026-07-22): a deficit trims the carb bank on days that can
        // afford it — bottom of the consensus band, never below it.
        let easy = FuelReadiness.readout(meals: [], sessions: [], workoutsToday: [],
                                         bodyMassKg: 70, goal: goal(.leaner), now: now)
        #expect(easy.carbsFloorG == 175)          // 2.5 g/kg, down from the default 3
        let session = FuelReadiness.SessionInput(date: now, durationS: 1.5 * 3600, isRace: false)
        let moderate = FuelReadiness.readout(meals: [], sessions: [session], workoutsToday: [],
                                             bodyMassKg: 70, goal: goal(.leaner), now: now)
        #expect(moderate.carbsFloorG == 280)      // 4 g/kg, down from the default 5
    }

    @Test func leanerNeverTouchesTheLongRun() {
        // Big days keep their full load for every goal — the same protection as the energy pause.
        let long = FuelReadiness.SessionInput(date: now.addingTimeInterval(86_400),
                                              durationS: 2.6 * 3600, isRace: false)
        let r = FuelReadiness.readout(meals: [], sessions: [long], workoutsToday: [],
                                      bodyMassKg: 70, goal: goal(.leaner), now: now)
        #expect(r.carbsFloorG == 420)             // 6 g/kg — the work is funded, deficit or not
    }

    @Test func buildAddsSubstrateOnLighterDays() {
        let easy = FuelReadiness.readout(meals: [], sessions: [], workoutsToday: [],
                                         bodyMassKg: 70, goal: goal(.build), now: now)
        #expect(easy.carbsFloorG == 245)          // 3.5 g/kg
        let session = FuelReadiness.SessionInput(date: now, durationS: 1.5 * 3600, isRace: false)
        let moderate = FuelReadiness.readout(meals: [], sessions: [session], workoutsToday: [],
                                             bodyMassKg: 70, goal: goal(.build), now: now)
        #expect(moderate.carbsFloorG == 385)      // 5.5 g/kg — a little substrate for the rebuild
    }

    @Test func buildAddsASmallSurplusAndTrainingBurnStillAdds() {
        let ride = FuelReadiness.WorkoutInput(endedAt: now.addingTimeInterval(-3 * 3600),
                                              durationS: 3600, kcal: 500)
        let r = FuelReadiness.readout(meals: [], sessions: [], workoutsToday: [ride],
                                      bodyMassKg: 70, goal: goal(.build), now: now)
        #expect(r.kcalFloor == 2167 + 300 + 500)  // maintenance + surplus + the day's real burn
    }

    @Test func microFloorsAreSexAwareAndSum() {
        var lunch = meal(2, kcal: 600)
        lunch.potassiumMg = 800; lunch.magnesiumMg = 120; lunch.ironMg = 3.2; lunch.calciumMg = 250
        let female = FuelReadiness.readout(meals: [lunch], sessions: [], workoutsToday: [],
                                           bodyMassKg: 60,
                                           goal: .init(isMale: false), now: now)
        #expect(female.micros.ironFloorMg == 18)          // the runner's micro — female RDA
        #expect(female.micros.potassiumFloorMg == 2600)
        #expect(female.micros.ironMg == 3.2)
        #expect(female.micros.potassiumMg == 800)
        let unknown = FuelReadiness.readout(meals: [], sessions: [], workoutsToday: [],
                                            bodyMassKg: 70, now: now)
        #expect(unknown.micros.ironFloorMg == 13)         // sex unknown → neutral anchors
        #expect(unknown.micros.calciumFloorMg == 1000)
    }

    @Test func customNumbersOutrankTheMath() {
        let r = FuelReadiness.readout(meals: [], sessions: [], workoutsToday: [],
                                      bodyMassKg: 70,
                                      goal: goal(.custom, customKcal: 2800, customCarbs: 400), now: now)
        #expect(r.kcalFloor == 2800)
        #expect(r.carbsFloorG == 400)             // the athlete's carbs replace the session key
        #expect(r.carbsHighG == 400 + 140)        // band width (2 g/kg) still shows above it
    }
}
