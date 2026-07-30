import Foundation
import Testing
@testable import Momentum

/// Pins `FuelTips` — the one deterministic line under the fuel readout. The rules are ranked and
/// sparse on purpose: the refuel banner and a fueled bar both mean SILENCE, and each rule fires
/// only in its window. Every case builds a readout by hand so the trigger is explicit.
struct FuelTipsTests {

    // MARK: Readout factory (engine-shaped, with quiet defaults)

    private func readout(kcal: Int = 1200, carbs: Int = 120, protein: Int = 80, fat: Int = 45,
                         sodium: Int = 1400, meals: Int = 2, pending: Int = 0,
                         kcalFloor: Int = 2100, carbsFloor: Int = 350, carbsHigh: Int = 490,
                         proteinFloor: Int = 98, fatFloor: Int = 70, sodiumFloor: Int = 1500,
                         status: FuelReadiness.Status = .onTrack,
                         driving: String? = nil, raceEve: Bool = false, drivingIsToday: Bool = false,
                         refuelDue: Bool = false) -> FuelReadiness.DayReadout {
        FuelReadiness.DayReadout(
            kcal: kcal, carbsG: carbs, proteinG: protein, fatG: fat, sodiumMg: sodium,
            mealCount: meals, pendingCount: pending,
            kcalFloor: kcalFloor, carbsFloorG: carbsFloor, carbsHighG: carbsHigh,
            proteinFloorG: proteinFloor, fatFloorG: fatFloor, sodiumFloorMg: sodiumFloor,
            status: status, primary: .carbs, drivingSession: driving,
            raceEve: raceEve, drivingIsToday: drivingIsToday,
            kcalIsGoal: false, goalNote: nil,
            headline: "", refuelDue: refuelDue,
            micros: .init(potassiumMg: 0, magnesiumMg: 0, ironMg: 0, calciumMg: 0,
                          potassiumFloorMg: 3000, magnesiumFloorMg: 370, ironFloorMg: 13,
                          calciumFloorMg: 1000))
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    // MARK: Silence is a feature

    @Test func refuelWindowOwnsItsMoment() {
        // Even with every other rule primed, the banner speaks alone.
        let r = readout(protein: 10, sodium: 0, status: .behind,
                        driving: "today's long session (2h)", drivingIsToday: true, refuelDue: true)
        #expect(FuelTips.line(readout: r, now: date(hour: 19)) == nil)
    }

    @Test func emptyDaySaysNothing() {
        let r = readout(kcal: 0, carbs: 0, protein: 0, sodium: 0, meals: 0, status: .empty)
        #expect(FuelTips.line(readout: r, now: date(hour: 9)) == nil)
    }

    @Test func quietWhenTheDayIsSimplyFine() {
        // Midday, on track, floors pacing along — no rule fires, no filler line.
        let r = readout(protein: 80, sodium: 1200, status: .onTrack)
        #expect(FuelTips.line(readout: r, now: date(hour: 14)) == nil)
    }

    @Test func fueledEveningEarnsSilenceNotPraise() {
        let r = readout(carbs: 360, protein: 99, sodium: 1600, status: .fueled)
        #expect(FuelTips.line(readout: r, now: date(hour: 20)) == nil)
    }

    // MARK: The ranked rules

    @Test func raceEveLeadsEverything() {
        let r = readout(status: .behind, driving: "tomorrow's race (3h 30m)", raceEve: true)
        let line = FuelTips.line(readout: r, now: date(hour: 9))
        #expect(line == "Race eve — bank carbs steadily through the day, not in one late dinner.")
    }

    @Test func raceEveGoesQuietOnceFueled() {
        let r = readout(carbs: 560, protein: 99, sodium: 1600, status: .fueled,
                        driving: "tomorrow's race (3h 30m)", raceEve: true)
        #expect(FuelTips.line(readout: r, now: date(hour: 9)) == nil)
    }

    @Test func morningFrontLoadNamesTheSession() {
        let r = readout(status: .onTrack, driving: "today's long session (1h 45m)", drivingIsToday: true)
        let line = FuelTips.line(readout: r, now: date(hour: 8, minute: 30))
        #expect(line == "Carbs eaten early do the most for today's long session (1h 45m) — breakfast is part of the workout.")
    }

    @Test func morningRuleExpiresAtElevenAndForTomorrowSessions() {
        let today = readout(status: .onTrack, driving: "today's session (1h 10m)", drivingIsToday: true)
        #expect(FuelTips.line(readout: today, now: date(hour: 11)) == nil)
        // Nor before 05:00 — no "breakfast" coaching in the middle of the night.
        #expect(FuelTips.line(readout: today, now: date(hour: 3)) == nil)
        let tomorrow = readout(status: .onTrack, driving: "tomorrow's session (1h 10m)")
        #expect(FuelTips.line(readout: tomorrow, now: date(hour: 8)) == nil)
    }

    @Test func sweatDaySodiumGapAfterNoon() {
        // Sweat add-on raised the floor (2900 > baseline) and less than half is banked.
        let r = readout(sodium: 1200, sodiumFloor: 2900, status: .onTrack)
        let line = FuelTips.line(readout: r, now: date(hour: 13))
        #expect(line == "Sweaty day — ≈1700 mg below the sodium floor. Salt your food.")
        // A baseline-only floor never triggers it, no matter the gap.
        let easy = readout(sodium: 0, sodiumFloor: FuelReadiness.sodiumBaselineMg, status: .onTrack)
        #expect(FuelTips.line(readout: easy, now: date(hour: 13)) == nil)
    }

    @Test func eveningProteinGapSuggestsDinner() {
        let r = readout(protein: 40, status: .onTrack)   // 40 < 98 × 3/4
        let line = FuelTips.line(readout: r, now: date(hour: 18))
        #expect(line == "≈58 g of protein to go — a protein-forward dinner closes it.")
        // Close enough to the floor → quiet.
        let near = readout(protein: 90, status: .onTrack)
        #expect(FuelTips.line(readout: near, now: date(hour: 18)) == nil)
    }

    @Test func lateBehindCarbsCountsDinnerIn() {
        let r = readout(carbs: 200, protein: 95, status: .behind)
        let line = FuelTips.line(readout: r, now: date(hour: 20))
        #expect(line == "≈150 g of carbs still to bank — dinner counts.")
    }
}
