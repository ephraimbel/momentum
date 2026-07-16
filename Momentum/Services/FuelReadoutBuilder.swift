import Foundation
import SwiftData

/// Maps the SwiftData world into `FuelReadiness` inputs — ONE place, so the Fuel page and the
/// coach's context digest judge the same day by the same rules (the engine itself stays pure).
enum FuelReadoutBuilder {

    @MainActor
    static func readout(meals: [Meal],
                        plan: TrainingPlan?,
                        workouts: [Workout],
                        profile: UserProfile?,
                        goalOverride: FuelReadiness.GoalInput? = nil,
                        massOverride: Double? = nil,
                        now: Date = Date()) -> FuelReadiness.DayReadout {
        let cal = Calendar.current
        let mealInputs = meals.prefix(80).map {
            FuelReadiness.MealInput(eatenAt: $0.eatenAt, kcal: $0.kcal, carbsG: $0.carbsG,
                                    proteinG: $0.proteinG, fatG: $0.fatG, sodiumMg: $0.sodiumMg,
                                    potassiumMg: $0.potassiumMg, magnesiumMg: $0.magnesiumMg,
                                    ironMg: $0.ironMg, calciumMg: $0.calciumMg)
        }
        // Open running sessions today/tomorrow — the carb target's driver.
        let sessions: [FuelReadiness.SessionInput] = (plan?.sessions ?? [])
            .filter { $0.discipline == .running && $0.status != .completed }
            .filter { cal.isDate($0.date, inSameDayAs: now) || cal.isDate($0.date, inSameDayAs: now.addingTimeInterval(86_400)) }
            .compactMap { s in
                FuelingGuide.estimatedDurationS(distanceM: s.targetDistanceM, paceSPerKm: s.targetPaceSPerKm,
                                                durationS: s.targetDurationS)
                    .map { FuelReadiness.SessionInput(date: s.date, durationS: $0, isRace: s.runType == .race) }
            }
        let today: [FuelReadiness.WorkoutInput] = workouts.prefix(20)
            .filter { cal.isDate($0.startedAt, inSameDayAs: now) }
            .map { FuelReadiness.WorkoutInput(endedAt: $0.startedAt.addingTimeInterval($0.durationS),
                                              durationS: $0.durationS, kcal: $0.calories.map(Int.init)) }
        return FuelReadiness.readout(meals: Array(mealInputs), sessions: sessions,
                                     workoutsToday: today,
                                     bodyMassKg: massOverride ?? profile?.bodyMassKg,
                                     goal: goalOverride ?? goalInput(profile), now: now)
    }

    /// The saved adjuster choice, engine-shaped. Missing/unknown → the classic floors.
    static func goalInput(_ p: UserProfile?) -> FuelReadiness.GoalInput {
        guard let p else { return .init() }
        return .init(kind: p.fuelGoalKind.flatMap { FuelReadiness.GoalInput.Kind(rawValue: $0) } ?? .fuel,
                     heightCm: p.heightCm,
                     birthYear: p.birthYear,
                     isMale: p.sex == "male" ? true : (p.sex == "female" ? false : nil),
                     customKcal: p.fuelCustomKcal,
                     customProteinG: p.fuelCustomProteinG,
                     customCarbsG: p.fuelCustomCarbsG,
                     customFatG: p.fuelCustomFatG,
                     customSodiumMg: p.fuelCustomSodiumMg)
    }

    /// One compact line for the coach's context ("how am I fueling?" gets a personal answer).
    /// nil until the athlete has logged something today — the coach never nags an empty journal.
    static func coachLine(_ r: FuelReadiness.DayReadout) -> String? {
        guard r.mealCount > 0 else { return nil }
        var line = "today ≈\(r.carbsG)g carbs vs \(r.carbsFloorG)g floor (\(r.status.rawValue))"
        line += " · protein \(r.proteinG)/\(r.proteinFloorG)g · fat \(r.fatG)/\(r.fatFloorG)g · sodium \(r.sodiumMg)/\(r.sodiumFloorMg)mg"
        line += " · energy \(r.kcal)/\(r.kcalFloor) kcal"
        if let d = r.drivingSession { line += " · carb target keyed to \(d)" }
        if r.pendingCount > 0 { line += " · \(r.pendingCount) meal(s) still estimating" }
        return line
    }
}
