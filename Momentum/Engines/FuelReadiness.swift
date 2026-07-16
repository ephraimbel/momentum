import Foundation

/// Fueling readiness (FUEL pillar, 2026-07-16) — the deterministic judge over logged meals: is this
/// athlete fueled for the training in front of them? Pure and unit-testable like every engine; the
/// AI only *estimates a meal's numbers* upstream (data entry, like HealthKit importing heart rate) —
/// every target and verdict here is rules-based sports-science consensus, in plain words.
///
/// Framing rules (non-negotiable, ENDURANCE-FOCUS §11 + no-shame):
///  - Every target is a FLOOR — "enough to fund the work" — never a ceiling. Under-fueling gets the
///    gentle warning; meeting/exceeding a floor is simply "fueled". No deficits, no diet language.
///  - Carbs key to the biggest session in the next ~36 h (glycogen fills overnight — the eve matters).
///  - Energy floor ≈ baseline (~30 kcal/kg) + the day's training burn.
///  - Protein floor: endurance + strength-for-runners band (1.4 g/kg).
///  - Sodium: a daily baseline plus sweat losses (~700 mg per long-session hour).
///  - Missing body mass falls back to 70 kg — bands are deliberately wide, every number reads "≈".
enum FuelReadiness {

    // MARK: Inputs (plain values — mapped from SwiftData at the call site, so the engine stays pure)

    struct MealInput: Sendable {
        let eatenAt: Date
        let kcal: Int?
        let carbsG: Int?
        let proteinG: Int?
        var fatG: Int? = nil
        let sodiumMg: Int?
        /// false while an estimate is pending — pending meals are excluded from totals but counted,
        /// so the readout can say "2 meals still estimating" instead of quietly under-reporting.
        var hasNumbers: Bool { carbsG != nil || kcal != nil }
    }

    struct SessionInput: Sendable {
        let date: Date
        /// Estimated duration (explicit, or distance × pace — `FuelingGuide.estimatedDurationS`).
        let durationS: Double
        let isRace: Bool
    }

    struct WorkoutInput: Sendable {
        let endedAt: Date
        let durationS: Double
        let kcal: Int?
    }

    /// How the daily energy target is set (the fueling adjuster). Default `.fuel` reproduces the
    /// classic floors exactly; the other kinds move the ENERGY number only — carbs stay keyed to
    /// training (that's the moat), protein rises to protect muscle in a deficit, and the RED-S
    /// guard means a deficit never dips below basal headroom and always funds the day's real burn.
    struct GoalInput: Sendable {
        enum Kind: String, Sendable, CaseIterable { case fuel, leaner, build, custom }
        var kind: Kind = .fuel
        var heightCm: Double? = nil
        var birthYear: Int? = nil
        /// nil = unknown/unspecified → the sex-neutral BMR constant.
        var isMale: Bool? = nil
        var customKcal: Int? = nil
        var customProteinG: Int? = nil
        var customCarbsG: Int? = nil
        var customFatG: Int? = nil
        var customSodiumMg: Int? = nil
    }

    // MARK: Output

    enum Status: String, Sendable { case fueled, onTrack, behind, empty }

    struct DayReadout: Sendable, Equatable {
        // Eaten so far today (numbered meals only).
        let kcal: Int
        let carbsG: Int
        let proteinG: Int
        let fatG: Int
        let sodiumMg: Int
        let mealCount: Int
        let pendingCount: Int
        // Floors for the day (lower bound of each band; carbs also carries the band's top for display).
        let kcalFloor: Int
        let carbsFloorG: Int
        let carbsHighG: Int
        let proteinFloorG: Int
        let fatFloorG: Int
        let sodiumFloorMg: Int
        /// Carb readiness vs the driving session — the headline judgment.
        let status: Status
        /// "Tomorrow's long run (1h 45m)" / "today's race" — what the carb target is keyed to. nil = easy horizon.
        let drivingSession: String?
        /// The driving session is tomorrow's race (the classic all-day carb load) / is later today
        /// (front-loading matters). Both false on an easy horizon — `FuelTips` keys off these.
        let raceEve: Bool
        let drivingIsToday: Bool
        /// The energy number is a chosen GOAL (leaner/build/custom), not the classic floor —
        /// display drops the "+" and reads "today's goal".
        let kcalIsGoal: Bool
        /// One honest line when the goal steps aside ("Deficit paused — big session ahead.").
        let goalNote: String?
        /// Plain-words one-liner for the page header.
        let headline: String
        /// A completed ≥1h session ended inside the refuel window with no meal since.
        let refuelDue: Bool
    }

    // MARK: Constants (authoritative — change here, tests pin them)

    static let baselineKcalPerKg = 30.0
    static let proteinPerKgFloor = 1.4
    /// Fat floor (~1 g/kg) — hormonal health and vitamin absorption need a minimum; endurance
    /// athletes chronically cutting fat is the same under-fueling story. Never a ceiling.
    static let fatPerKgFloor = 1.0
    static let sodiumBaselineMg = 1500
    static let sodiumPerLongHourMg = 700
    static let fallbackMassKg = 70.0
    // Goal math (Mifflin-St Jeor BMR × a daily-life base; the day's REAL training burn adds on top,
    // so no survey "activity level" ever double-counts a workout).
    static let activityBase = 1.35
    static let leanerDeficitKcal = 400       // gentle: ~0.25-0.4 kg/week, training protected
    static let buildSurplusKcal = 300
    static let leanerBMRGuard = 1.1          // a deficit never dips below 1.1 × basal (+ burn)
    static let proteinPerKgLeaner = 1.9      // protect muscle inside a deficit
    static let proteinPerKgBuild = 1.6
    static let fallbackHeightCm = 172.0
    static let fallbackAge = 35
    /// Carb g/kg floors by the driving session's demand tier.
    static let carbsPerKgEasy = 3.0        // no meaningful session in the horizon
    static let carbsPerKgModerate = 5.0    // ≥1 h session today/tomorrow
    static let carbsPerKgLong = 6.0        // ≥2.5 h session today/tomorrow
    static let carbsPerKgRaceEve = 8.0     // race tomorrow — the classic load
    /// Band width shown above each floor (floor…floor+width is "the band").
    static let carbsBandWidthPerKg = 2.0
    /// Refuel window after a ≥1 h session (FuelingGuide's "within the hour", with grace).
    static let refuelWindowS: Double = 90 * 60
    /// The waking day the pacing curve spans (06:00 → 22:00).
    static let dayStartHour = 6.0, dayEndHour = 22.0

    // MARK: The judgment

    static func readout(meals: [MealInput],
                        sessions: [SessionInput],
                        workoutsToday: [WorkoutInput],
                        bodyMassKg: Double?,
                        goal: GoalInput = GoalInput(),
                        now: Date,
                        calendar: Calendar = .current) -> DayReadout {
        let kg = bodyMassKg ?? fallbackMassKg
        let today = meals.filter { calendar.isDate($0.eatenAt, inSameDayAs: now) }
        let numbered = today.filter(\.hasNumbers)
        let kcal = numbered.compactMap(\.kcal).reduce(0, +)
        let carbs = numbered.compactMap(\.carbsG).reduce(0, +)
        let protein = numbered.compactMap(\.proteinG).reduce(0, +)
        let fat = numbered.compactMap(\.fatG).reduce(0, +)
        let sodium = numbered.compactMap(\.sodiumMg).reduce(0, +)

        // The driving session: the longest run today or tomorrow (glycogen is filled the day before).
        let horizon = sessions.filter {
            calendar.isDate($0.date, inSameDayAs: now)
                || calendar.isDate($0.date, inSameDayAs: now.addingTimeInterval(86_400))
        }
        let driver = horizon.max { $0.durationS < $1.durationS }

        let carbsPerKg: Double
        var drivingLabel: String?
        var raceEve = false, drivingIsToday = false
        if let driver, driver.durationS >= FuelingGuide.carbsFromS {
            let tomorrow = !calendar.isDate(driver.date, inSameDayAs: now)
            let long = driver.durationS >= FuelingGuide.highCarbFromS
            carbsPerKg = driver.isRace && tomorrow ? carbsPerKgRaceEve : (long ? carbsPerKgLong : carbsPerKgModerate)
            raceEve = driver.isRace && tomorrow
            drivingIsToday = !tomorrow
            let when = tomorrow ? "tomorrow's" : "today's"
            let what = driver.isRace ? "race" : (long ? "long session" : "session")
            drivingLabel = "\(when) \(what) (\(durationLabel(driver.durationS)))"
        } else {
            carbsPerKg = carbsPerKgEasy
        }

        let trainedKcal = workoutsToday.compactMap(\.kcal).reduce(0, +)
        // Energy: the classic floor, or the adjuster's goal. A deficit steps aside when the
        // training does the talking (race eve / a long driver) — fuel the work first.
        let age = goal.birthYear.map { max(14, calendar.component(.year, from: now) - $0) } ?? fallbackAge
        let basal = bmr(kg: kg, heightCm: goal.heightCm ?? fallbackHeightCm, age: age, isMale: goal.isMale)
        let maintenance = basal * activityBase
        let bigDay = raceEve || carbsPerKg >= carbsPerKgLong
        var kcalIsGoal = true
        var goalNote: String?
        let kcalBase: Double
        switch goal.kind {
        case .fuel:
            kcalIsGoal = false
            kcalBase = baselineKcalPerKg * kg
        case .leaner:
            if bigDay {
                kcalBase = maintenance
                goalNote = "Deficit paused — big session ahead. Fuel the work first."
            } else {
                kcalBase = max(maintenance - Double(leanerDeficitKcal), basal * leanerBMRGuard)
            }
        case .build:
            kcalBase = maintenance + Double(buildSurplusKcal)
        case .custom:
            kcalBase = Double(goal.customKcal ?? Int(maintenance.rounded()))
        }
        let kcalFloor = Int(kcalBase.rounded()) + trainedKcal

        var carbsFloor = Int((carbsPerKg * kg).rounded())
        var carbsHigh = Int(((carbsPerKg + carbsBandWidthPerKg) * kg).rounded())
        if goal.kind == .custom, let c = goal.customCarbsG {
            carbsFloor = c
            carbsHigh = c + Int((carbsBandWidthPerKg * kg).rounded())
        }
        let proteinPerKg: Double = switch goal.kind {
        case .leaner: proteinPerKgLeaner
        case .build: proteinPerKgBuild
        default: proteinPerKgFloor
        }
        let proteinFloor = goal.kind == .custom
            ? (goal.customProteinG ?? Int((proteinPerKgFloor * kg).rounded()))
            : Int((proteinPerKg * kg).rounded())
        let fatFloor = goal.kind == .custom
            ? (goal.customFatG ?? Int((fatPerKgFloor * kg).rounded()))
            : Int((fatPerKgFloor * kg).rounded())
        let doneS: Double = workoutsToday.map(\.durationS).reduce(0, +)
        let plannedTodayS: Double = horizon
            .filter { calendar.isDate($0.date, inSameDayAs: now) }
            .map(\.durationS).reduce(0, +)
        let longHours: Double = (doneS + plannedTodayS).clamped(to: 0...(12 * 3600)) / 3600
        let sweatMg: Double = Double(sodiumPerLongHourMg) * max(0, longHours - 1)
        let sodiumFloor = goal.kind == .custom
            ? (goal.customSodiumMg ?? sodiumBaselineMg + Int(sweatMg.rounded()))
            : sodiumBaselineMg + Int(sweatMg.rounded())

        // Status paces the carb floor across the waking day, so 09:00 isn't judged against dinner.
        let status: Status
        if today.isEmpty {
            status = .empty
        } else {
            let hour = Double(calendar.component(.hour, from: now)) + Double(calendar.component(.minute, from: now)) / 60
            let dayFraction = ((hour - dayStartHour) / (dayEndHour - dayStartHour)).clamped(to: 0.15...1)
            let expected = Double(carbsFloor) * dayFraction
            if Double(carbs) >= Double(carbsFloor) { status = .fueled }
            else if Double(carbs) >= expected * 0.8 { status = .onTrack }
            else { status = .behind }
        }

        // Refuel window: last ≥1 h workout ended recently and nothing eaten since.
        let refuelDue = workoutsToday.contains { w in
            w.durationS >= FuelingGuide.carbsFromS
                && now.timeIntervalSince(w.endedAt) >= 0
                && now.timeIntervalSince(w.endedAt) <= refuelWindowS
                && !today.contains { $0.eatenAt > w.endedAt }
        }

        return DayReadout(
            kcal: kcal, carbsG: carbs, proteinG: protein, fatG: fat, sodiumMg: sodium,
            mealCount: today.count, pendingCount: today.count - numbered.count,
            kcalFloor: kcalFloor, carbsFloorG: carbsFloor, carbsHighG: carbsHigh,
            proteinFloorG: proteinFloor, fatFloorG: fatFloor, sodiumFloorMg: sodiumFloor,
            status: status, drivingSession: drivingLabel,
            raceEve: raceEve, drivingIsToday: drivingIsToday,
            kcalIsGoal: kcalIsGoal, goalNote: goalNote,
            headline: headline(status: status, carbs: carbs, floor: carbsFloor,
                               driving: drivingLabel, refuelDue: refuelDue),
            refuelDue: refuelDue)
    }

    /// Plain words, no shame: what's true and the one next step.
    private static func headline(status: Status, carbs: Int, floor: Int,
                                 driving: String?, refuelDue: Bool) -> String {
        if refuelDue { return "Refuel window — carbs + protein now beat carbs + protein later." }
        let target = driving.map { "ready for \($0)" } ?? "for an easy day"
        switch status {
        case .empty: return "Log your first meal — aiming ≈\(floor) g of carbs \(target)."
        case .behind: return "≈\(carbs) g of carbs so far — building toward ≈\(floor) g \(target)."
        case .onTrack: return "On track — ≈\(carbs) g of \(floor) g \(target)."
        case .fueled: return "Fueled — ≈\(carbs) g of carbs banked \(target)."
        }
    }

    /// Mifflin-St Jeor — the standard resting-energy estimate. Unknown sex uses the midpoint
    /// constant; every output downstream reads "≈" anyway.
    static func bmr(kg: Double, heightCm: Double, age: Int, isMale: Bool?) -> Double {
        let sexTerm: Double = isMale == true ? 5 : (isMale == false ? -161 : -78)
        return 10 * kg + 6.25 * heightCm - 5 * Double(age) + sexTerm
    }

    private static func durationLabel(_ s: Double) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { min(max(self, r.lowerBound), r.upperBound) }
}
