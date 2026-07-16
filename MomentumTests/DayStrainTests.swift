import Testing
import Foundation
@testable import Momentum

/// Recovery Hub plan §4.3 fixtures — daily strain: today's workouts + ambient movement, scaled
/// against chronic fitness (CTL) through the saturating curve.
@MainActor
struct DayStrainTests {
    /// Fixed clock + UTC calendar so day-bucketing is deterministic on any machine.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09, mid-morning UTC
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func run(minutes: Double, rpe: Int = 6, at startedAt: Date? = nil) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = startedAt ?? now.addingTimeInterval(-3_600)   // an hour ago, same local day
        w.durationS = minutes * 60
        w.perceivedEffort = rpe
        return w
    }

    private func strain(workouts: [Workout] = [],
                        steps: Double? = nil,
                        kcal: Double? = nil,
                        hrAvg: Double? = nil,
                        hrBaseline: HealthBaselines.Baseline? = nil,
                        ctl: Double = 60) -> DayStrain {
        DayStrain(workoutsToday: workouts, ambientSteps: steps, ambientActiveKcal: kcal,
                  walkingHRAvg: hrAvg, walkingHRBaseline: hrBaseline,
                  chronicLoad: ctl, now: now, calendar: cal)
    }

    @Test func restDayIsZeroAndLight() {
        // No workouts, no ambient signal → an honest zero, worn proudly (kept rest days render).
        let s = strain()
        #expect(s.score == 0)
        #expect(s.band == .light)
        #expect(s.workoutLoad == 0)
        #expect(s.ambientLoad == 0)
    }

    @Test func anchorPins46And71() {
        // raw = reference: 10 min × RPE 6 = 60 load vs CTL 60 → 100·(1 − e^(−1/1.6)) = 46.47 → 46.
        let one = strain(workouts: [run(minutes: 10)], ctl: 60)
        #expect(one.workoutLoad == 60)
        #expect(one.score == 46)
        #expect(one.band == .moderate)
        // raw = 2×reference: 20 min → 120 → 100·(1 − e^(−1.25)) = 71.35 → 71.
        let two = strain(workouts: [run(minutes: 20)], ctl: 60)
        #expect(two.score == 71)
        #expect(two.band == .hard)
        // raw = 3×reference: 30 min → 180 → 100·(1 − e^(−1.875)) = 84.66 → 85.
        let three = strain(workouts: [run(minutes: 30)], ctl: 60)
        #expect(three.score == 85)
        #expect(three.band == .peak)
    }

    @Test func scoreIsMonotoneInLoadAndNeverExceeds100() {
        // Sweep ambient 0 → 600 load against reference 50: the curve only ever climbs, and the
        // ceiling holds even deep into saturation (600/(1.6·50) = 7.5 → 99.94, rounds to 100).
        var last = -1
        for steps in stride(from: 0.0, through: 60_000, by: 1_000) {
            let s = strain(steps: steps, ctl: 50)
            #expect(s.score >= last)
            #expect(s.score <= 100)
            last = s.score
        }
        #expect(last == 100)
    }

    @Test func coldStartFloorReadsHighButNever100() {
        // CTL 4 (week one) floors to reference 30: an easy hour (RPE 4 → load 240) reads
        // 240/(1.6·30) = 5 → 100·(1 − e^(−5)) = 99.33 → 99. A big day for a beginner reads
        // honestly big — but not a pinned 100, which the unfloored reference 4 would produce.
        let s = strain(workouts: [run(minutes: 60, rpe: 4)], ctl: 4)
        #expect(s.score == 99)
        #expect(s.score < 100)
        #expect(s.band == .peak)
        // The floor makes CTL 4 and CTL 30 score identically — the curve only relaxes above it.
        #expect(strain(workouts: [run(minutes: 60, rpe: 4)], ctl: 30).score == s.score)
    }

    @Test func stepsAndKcalAreExclusiveNeverSummed() {
        #expect(strain(steps: 8_000).ambientLoad == 80)              // steps primary: 8000/1000 × 10
        #expect(strain(kcal: 400).ambientLoad == 100)                // kcal fallback: 400 × 0.25
        #expect(strain(steps: 8_000, kcal: 400).ambientLoad == 80)   // both present → steps win, never 180
        #expect(strain(steps: -500).ambientLoad == 0)                // netting glitch clamps, never negative
    }

    @Test func walkingHRMultiplierClampsBothEnds() {
        let baseline = HealthBaselines.Baseline(mean: 100, sd: 5, dayCount: 30, windowDays: 60)
        // 10k steps → base 100; the ratio is leashed to [0.9, 1.15].
        let low = strain(steps: 10_000, hrAvg: 70, hrBaseline: baseline)     // 0.7 → clamps to 0.9
        #expect(abs(low.ambientLoad - 90) < 0.000_1)
        let high = strain(steps: 10_000, hrAvg: 130, hrBaseline: baseline)   // 1.3 → clamps to 1.15
        #expect(abs(high.ambientLoad - 115) < 0.000_1)
        let inBand = strain(steps: 10_000, hrAvg: 105, hrBaseline: baseline) // 1.05 passes through
        #expect(abs(inBand.ambientLoad - 105) < 0.000_1)
        // Missing either half of the signal → no nudge, never a guess.
        #expect(strain(steps: 10_000, hrAvg: 105).ambientLoad == 100)
        #expect(strain(steps: 10_000, hrBaseline: baseline).ambientLoad == 100)
    }

    @Test func dayKeyExcludes2350AndIncludes0010() {
        // A 23:50 session belongs to yesterday's strain; a 00:10 session to today's.
        let todayStart = cal.startOfDay(for: now)
        let lateYesterday = run(minutes: 10, at: todayStart.addingTimeInterval(-600))
        let earlyToday = run(minutes: 10, at: todayStart.addingTimeInterval(600))
        let s = strain(workouts: [lateYesterday, earlyToday], ctl: 60)
        #expect(s.workoutLoad == 60)    // only the 00:10 session counts
        #expect(s.score == 46)          // and alone it lands the raw-=-reference anchor
    }

    @Test func dstSpringForwardDayBucketsByLocalDay() {
        // America/New_York 2025-03-09 — the 23-hour spring-forward day (02:00 jumps to 03:00).
        // Sessions on both sides of the skipped hour bucket to the same local day; 23:50 the
        // night before stays out. startOfDay must survive the shortened day.
        var nyc = Calendar(identifier: .gregorian)
        nyc.timeZone = TimeZone(identifier: "America/New_York")!
        let noon = nyc.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 12))!
        let beforeSkip = run(minutes: 10,
                             at: nyc.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 1, minute: 30))!)
        let afterSkip = run(minutes: 10,
                            at: nyc.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 8))!)
        let lateYesterday = run(minutes: 10,
                                at: nyc.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 23, minute: 50))!)
        let s = DayStrain(workoutsToday: [beforeSkip, afterSkip, lateYesterday],
                          chronicLoad: 60, now: noon, calendar: nyc)
        #expect(s.workoutLoad == 120)
    }

    @Test func bandBoundaries() {
        // 0–24 light · 25–49 moderate · 50–74 hard · 75+ peak.
        #expect(DayStrain.band(0) == .light)
        #expect(DayStrain.band(24) == .light)
        #expect(DayStrain.band(25) == .moderate)
        #expect(DayStrain.band(49) == .moderate)
        #expect(DayStrain.band(50) == .hard)
        #expect(DayStrain.band(74) == .hard)
        #expect(DayStrain.band(75) == .peak)
        #expect(DayStrain.band(100) == .peak)
    }
}
