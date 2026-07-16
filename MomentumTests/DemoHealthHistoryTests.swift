import Testing
import Foundation
import HealthKit
@testable import Momentum

/// The `--health-recovery-demo` / `--health-recovery-strained` synthetic-history hook
/// (RECOVERY-HUB-PLAN §9 P1, landed with P4): pure day-index math — no RNG, no `Date.now`
/// dependence — so the populated hub renders the same charts on every launch. These fixtures pin
/// the shapes the cards and engines depend on.
struct DemoHealthHistoryTests {
    /// Fixed clock + UTC calendar so day-bucketing is deterministic on any machine.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09, mid-morning UTC
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: Daily histories

    @Test func historiesAreDeterministicAscendingAndWindowSized() {
        let a = HealthService.demoDailyHistory(.restingHeartRate, days: 30, scenario: .rested,
                                               now: now, calendar: cal)!
        let b = HealthService.demoDailyHistory(.restingHeartRate, days: 30, scenario: .rested,
                                               now: now, calendar: cal)!
        #expect(a.count == 30)
        #expect(a.map(\.day) == b.map(\.day))          // same launch → same chart
        #expect(a.map(\.value) == b.map(\.value))
        #expect(a.map(\.day) == a.map(\.day).sorted()) // ascending, like the real reduction
        #expect(a.last?.day == cal.startOfDay(for: now))
        // The 60-day windows (wrist temp / walking HR baselines) are honored.
        #expect(HealthService.demoDailyHistory(.walkingHeartRateAverage, days: 60, scenario: .rested,
                                               now: now, calendar: cal)?.count == 60)
    }

    @Test func restedSeriesArePlausibleAndLandOnTheLiveDemoStatic() {
        let hrv = HealthService.demoDailyHistory(.heartRateVariabilitySDNN, days: 30,
                                                 scenario: .rested, now: now, calendar: cal)!
        // This morning ≈ the live `RecoverySignals.demo` (68 ms), drifting gently upward.
        #expect(abs(hrv.last!.value - 68.0) < 1.0)
        let firstHalf = hrv.prefix(15).map(\.value).reduce(0, +) / 15.0
        let secondHalf = hrv.suffix(15).map(\.value).reduce(0, +) / 15.0
        #expect(secondHalf > firstHalf)
        for entry in hrv { #expect(entry.value > 55.0 && entry.value < 75.0) }

        let rhr = HealthService.demoDailyHistory(.restingHeartRate, days: 30,
                                                 scenario: .rested, now: now, calendar: cal)!
        for entry in rhr { #expect(entry.value > 49.0 && entry.value < 55.0) }   // ~52 ± 2
        #expect(abs(rhr.last!.value - 52.0) < 1.0)     // the live static shows 52
    }

    @Test func strainedHRVReadsSuppressedAgainstItsOwnBaseline() {
        let hrv = HealthService.demoDailyHistory(.heartRateVariabilitySDNN, days: 30,
                                                 scenario: .strained, now: now, calendar: cal)!
        let base = HealthBaselines.build(from: hrv, windowDays: 30, now: now, calendar: cal)
        #expect(base?.isEstablished == true)
        #expect(abs(hrv.last!.value - 46.0) < 1.0)     // the live static's 46 ms morning
        #expect(hrv.last!.value < base!.lower)         // clearly below the personal band
    }

    @Test func strainedRespiratoryAndTempDeviateAboveTheirNorms() {
        // The illness-watch pair must actually deviate against baselines built from their own
        // series — that's what renders the strained state + lilac watch on the sim.
        let resp = HealthService.demoDailyHistory(.respiratoryRate, days: 30,
                                                  scenario: .strained, now: now, calendar: cal)!
        let respBase = HealthBaselines.build(from: resp, windowDays: 30, now: now, calendar: cal)!
        #expect(respBase.z(resp.last!.value) > 1.5)

        let temp = HealthService.demoDailyHistory(.appleSleepingWristTemperature, days: 60,
                                                  scenario: .strained, now: now, calendar: cal)!
        let tempBase = HealthBaselines.build(from: temp, windowDays: 60, now: now, calendar: cal)!
        #expect(temp.last!.value - tempBase.mean > 0.4)   // running ~half a degree warm
    }

    @Test func unscriptedIdentifiersFallThroughToTheRealQuery() {
        #expect(HealthService.demoDailyHistory(.oxygenSaturation, days: 30, scenario: .rested,
                                               now: now, calendar: cal) == nil)
    }

    // MARK: Sleep nights

    @Test func sleepNightsMatchTheRealQueryShapes() {
        let nights = HealthService.demoSleepNights(days: 60, scenario: .rested, now: now, calendar: cal)
        #expect(nights.count == 13)                    // 14 mornings, one missing (hollow column)
        #expect(nights.map(\.date) == nights.map(\.date).sorted())
        #expect(nights.filter { $0.asleepH < 7.0 }.count == 1)   // exactly one dip night (6.8 h — retuned so 14-day debt reads "being paid down", not a 5 h wall)
        for night in nights {
            // The three asleep stages sum exactly to the union duration — the invariant the real
            // single-best-source assembly guarantees; awake rides on top (~5% of the night).
            let stageSum = (night.coreS ?? 0) + (night.deepS ?? 0) + (night.remS ?? 0)
            #expect(abs(stageSum - night.asleepH * 3600.0) < 1.0)
            #expect(night.awakeS! > 0.0 && night.awakeS! < 0.08 * night.inBedS!)
            #expect(night.asleepH > 5.5 && night.asleepH < 8.6)  // ~7.8 h ± 35 min + the short one
        }
        // Last night matches the live demo static (7.33 h) so the hero and the card agree.
        #expect(abs(nights.last!.asleepH - 7.33) < 0.001)
        // A smaller request is honored.
        #expect(HealthService.demoSleepNights(days: 7, scenario: .rested, now: now, calendar: cal).count == 7)
    }

    @Test func strainedNightsAreShortEndingAtLastNightsFiveFour() {
        let nights = HealthService.demoSleepNights(days: 60, scenario: .strained, now: now, calendar: cal)
        #expect(abs(nights.last!.asleepH - 5.4) < 0.001)   // = RecoverySignals.demoStrained.sleepHours
        for night in nights.suffix(5) { #expect(night.asleepH < 6.5) }
    }

    // MARK: Ambient movement

    @Test func ambientStepsVaryByWeekdayInsideTheBand() {
        var week: [Double] = []
        for ago in 0..<7 {
            let day = cal.date(byAdding: .day, value: -ago, to: cal.startOfDay(for: now))!
            let (steps, kcal) = HealthService.demoAmbientActivity(day: day, calendar: cal)
            #expect(steps! >= 7_500.0 && steps! <= 14_500.0)   // ~8–14k
            #expect(kcal! > 0.0)
            week.append(steps!)
        }
        #expect(Set(week).count > 3)   // genuinely varies across the week
        // Deterministic: the same day always renders the same movement.
        let day = cal.startOfDay(for: now)
        #expect(HealthService.demoAmbientActivity(day: day, calendar: cal).steps
                == HealthService.demoAmbientActivity(day: day, calendar: cal).steps)
    }
}
