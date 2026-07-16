import Testing
import Foundation
@testable import Momentum

/// Recovery Hub plan §4.4 fixtures — sleep scored through a training lens: need learning, debt
/// over present nights only, the CIRCULAR midpoint drift, and stage bands that wait for a norm.
struct SleepReportTests {
    /// Fixed clock + UTC calendar so day-bucketing is deterministic on any machine.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09 UTC
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// The wake-up morning `daysAgo` back from today (local startOfDay — the service's night key).
    private func morning(_ daysAgo: Int) -> Date {
        cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
    }

    /// A night record; `midpointMin` places the sleep-window midpoint that many minutes from the
    /// wake morning's midnight (negative = before midnight) via a symmetric 7-hour window — the
    /// engine only ever reads the midpoint, so the width is arbitrary.
    private func night(daysAgo: Int, asleepH: Double, coreS: Double? = nil, deepS: Double? = nil,
                       remS: Double? = nil, awakeS: Double? = nil, inBedS: Double? = nil,
                       midpointMin: Double? = nil) -> SleepReport.Night {
        var start: Date?, end: Date?
        if let midpointMin {
            let mid = morning(daysAgo).addingTimeInterval(midpointMin * 60)
            start = mid.addingTimeInterval(-3.5 * 3_600)
            end = mid.addingTimeInterval(3.5 * 3_600)
        }
        return SleepReport.Night(date: morning(daysAgo), asleepH: asleepH, coreS: coreS,
                                 deepS: deepS, remS: remS, awakeS: awakeS, inBedS: inBedS,
                                 sleepStart: start, sleepEnd: end)
    }

    private func build(_ nights: [SleepReport.Night]) -> SleepReport? {
        SleepReport.build(from: nights, now: now, calendar: cal)
    }

    // MARK: Last night's face value

    @Test func goldenNightSurfacesExactStageAndEfficiencyNumbers() throws {
        // 7.5 h asleep of 8 h in bed; stages 4 h core / 1.5 h deep / 2 h REM / 30 min awake.
        let r = try #require(build([night(daysAgo: 0, asleepH: 7.5, coreS: 14_400, deepS: 5_400,
                                          remS: 7_200, awakeS: 1_800, inBedS: 28_800)]))
        #expect(r.date == morning(0))
        #expect(r.asleepH == 7.5)
        #expect(r.stages == SleepReport.Stages(coreS: 14_400, deepS: 5_400, remS: 7_200, awakeS: 1_800))
        let efficiency = try #require(r.efficiencyPct)
        #expect(abs(efficiency - 93.75) < 0.000_1)    // 27 000 / 28 800
        #expect(r.efficiencyBand == .good)            // ≥ 90
        // Shares use the stage source's own asleep total (27 000 s): deep 20%, REM 26.67%.
        let deep = try #require(r.deepPct)
        let rem = try #require(r.remPct)
        #expect(abs(deep - 20) < 0.000_1)
        #expect(abs(rem - 26.6667) < 0.001)
        // One night: need stays the 8 h default; 30 min short still reads as met.
        #expect(r.needH == 8.0)
        #expect(r.durationBand == .good)
        #expect(abs(r.debt14H - 0.5) < 0.000_1)
        #expect(r.debtBand == .good)                                    // < 2 h
        // Not enough nights for drift or a stage norm — nil, never a guess.
        #expect(r.midpointDriftMin == nil && r.consistencyBand == nil)
        #expect(r.deepBand == nil && r.remBand == nil)
        #expect(r.stageNightCount == 1)
    }

    @Test func durationOnlyNightNeverPretendsToHaveStages() throws {
        // No source wrote stages: duration + efficiency only. 6 h of 7 h in bed = 85.71%.
        let r = try #require(build([night(daysAgo: 0, asleepH: 6.0, inBedS: 25_200)]))
        #expect(r.stages == nil)
        #expect(r.deepPct == nil && r.remPct == nil)
        #expect(r.deepBand == nil && r.remBand == nil)
        #expect(r.stageNightCount == 0)
        let efficiency = try #require(r.efficiencyPct)
        #expect(abs(efficiency - 85.7143) < 0.001)
        #expect(r.efficiencyBand == .fair)            // 80–90
        #expect(r.durationBand == .low)               // 2 h under the default need
    }

    @Test func emptyOrFutureOnlyInputIsNil() {
        #expect(build([]) == nil)
        // A future-keyed record (an in-progress early bedtime filed under tomorrow) is junk today.
        #expect(build([night(daysAgo: -1, asleepH: 7.0)]) == nil)
    }

    // MARK: Need learning

    @Test func needStaysDefaultUntilFourteenPlausibleNights() throws {
        // 13 plausible nights at 6.2 h + five 1.5 h naps + one 13 h artifact = 19 records, but
        // only the 13 count toward the threshold — need must hold the 8 h default. If naps
        // leaked in, the count would clear 14 and the 6.2 median would clamp to 7.0 instead.
        let plausible = (0..<13).map { night(daysAgo: $0, asleepH: 6.2) }
        let naps = (20..<25).map { night(daysAgo: $0, asleepH: 1.5) }
        let artifact = [night(daysAgo: 30, asleepH: 13.0)]
        let thirteen = try #require(build(plausible + naps + artifact))
        #expect(thirteen.needH == 8.0)

        // The 14th plausible night flips learning on: median 6.2 clamps up to the 7.0 floor.
        let fourteen = try #require(build(plausible + naps + artifact
                                          + [night(daysAgo: 13, asleepH: 6.2)]))
        #expect(abs(fourteen.needH - 7.0) < 0.000_1)
    }

    @Test func learnedNeedUsesTheMedianWithNapsExcludedAndClampsHigh() throws {
        // 14 nights alternating 7 h / 8 h → median 7.5, inside the 7–9 clamp. Three naps ride
        // along: were they counted, the 17-value median would read 7.0 — 7.5 proves exclusion.
        let alternating = (0..<14).map { night(daysAgo: $0, asleepH: $0.isMultiple(of: 2) ? 7.0 : 8.0) }
        let naps = (20..<23).map { night(daysAgo: $0, asleepH: 1.5) }
        let learned = try #require(build(alternating + naps))
        #expect(abs(learned.needH - 7.5) < 0.000_1)

        // A long sleeper's 9.6 h median clamps to the 9 h ceiling.
        let long = (0..<14).map { night(daysAgo: $0, asleepH: 9.6) }
        let clamped = try #require(build(long))
        #expect(abs(clamped.needH - 9.0) < 0.000_1)
    }

    // MARK: Debt

    @Test func debtSumsShortfallsOverPresentNightsOnly() throws {
        // Four present nights in the window: 6.5 (−1.5), 7.0 (−1.0), 8.5 (surplus — clamps to
        // 0, never banks credit), 6.0 (−2.0) → debt = 4.5 h vs the 8 h default need. The ten
        // missing mornings contribute NOTHING — zero-filled they'd add 10 × 8 = 80 h of fiction.
        // The 5 h night at day 20 sits outside the 14-day window and adds none either.
        let r = try #require(build([
            night(daysAgo: 0, asleepH: 6.5),
            night(daysAgo: 1, asleepH: 7.0),
            night(daysAgo: 3, asleepH: 8.5),
            night(daysAgo: 5, asleepH: 6.0),
            night(daysAgo: 20, asleepH: 5.0),
        ]))
        #expect(r.needH == 8.0)                       // 5 plausible nights — still learning
        #expect(abs(r.debt14H - 4.5) < 0.000_1)
        #expect(r.debtBand == .fair)                  // 2–5 h
    }

    @Test func debtBandBoundariesMatchTheSpec() throws {
        // 2 × 0.9 h short = 1.8 → good (< 2); 2 × 1.0 = 2.0 → fair (the 2–5 band is inclusive);
        // 3 × 2.0 = 6.0 → low (> 5).
        let good = try #require(build((0..<2).map { night(daysAgo: $0, asleepH: 7.1) }))
        #expect(abs(good.debt14H - 1.8) < 0.000_1)
        #expect(good.debtBand == .good)
        let fair = try #require(build((0..<2).map { night(daysAgo: $0, asleepH: 7.0) }))
        #expect(fair.debtBand == .fair)
        let low = try #require(build((0..<3).map { night(daysAgo: $0, asleepH: 6.0) }))
        #expect(low.debtBand == .low)
    }

    // MARK: Midpoint drift — the circular test

    @Test func midnightStraddlingMidpointsReadAsMinutesNotHours() throws {
        // Five recent nights, midpoints 23:10 · 23:40 · 00:05 · 00:30 · 01:00 — a schedule
        // drifting ACROSS midnight. Hand-derivation (angle/vector method, 0.25°/minute):
        //   angles: −12.5°, −5°, +1.25°, +7.5°, +15°
        //   C = mean cos ≈ 0.985925    S = mean sin ≈ 0.021513
        //   R = √(C² + S²) ≈ 0.986159 → √(−2 ln R) ≈ 0.166957 rad
        //   drift = 0.166957 × 1440/(2π) ≈ 38.26 min
        // A naive linear SD over minutes-of-day [1390, 1420, 5, 30, 60] reads ≈ 673 min — over
        // ELEVEN HOURS of fictional chaos. The circular method is the whole point of this test.
        let r = try #require(build([
            night(daysAgo: 0, asleepH: 7.0, midpointMin: 60),     // 01:00
            night(daysAgo: 1, asleepH: 7.0, midpointMin: 30),     // 00:30
            night(daysAgo: 2, asleepH: 7.0, midpointMin: 5),      // 00:05
            night(daysAgo: 3, asleepH: 7.0, midpointMin: -20),    // 23:40
            night(daysAgo: 4, asleepH: 7.0, midpointMin: -50),    // 23:10
        ]))
        let drift = try #require(r.midpointDriftMin)
        #expect(abs(drift - 38.26) < 0.3)             // the hand-derived value
        #expect(drift < 120)                          // minutes, never hours
        #expect(r.consistencyBand == .good)           // ≤ 45 min
    }

    @Test func fourMidpointNightsIsNotEnoughForDrift() throws {
        let four = (0..<4).map { night(daysAgo: $0, asleepH: 7.0, midpointMin: Double($0) * 15) }
        let r = try #require(build(four))
        #expect(r.midpointDriftMin == nil && r.consistencyBand == nil)

        // A fifth night without a sleep window doesn't count (4 usable midpoints)…
        let noWindow = try #require(build(four + [night(daysAgo: 4, asleepH: 7.0)]))
        #expect(noWindow.midpointDriftMin == nil)
        // …and neither does one outside the 14-day window — consistency is a current-state read.
        let stale = try #require(build(four + [night(daysAgo: 20, asleepH: 7.0, midpointMin: 0)]))
        #expect(stale.midpointDriftMin == nil)
    }

    @Test func consistencyBandsFollowTheDriftCuts() throws {
        // Midpoints 22:30 · 23:15 · 00:00 · 00:45 · 01:30 (±90, ±45, 0 min): symmetric so S = 0,
        // R = mean cos(±22.5°, ±11.25°, 0°) ≈ 0.961866 → √(−2 ln R) ≈ 0.278855 rad ≈ 63.91 min —
        // a real hour of nightly wander lands in fair (45–90).
        let loose = try #require(build((0..<5).map {
            night(daysAgo: $0, asleepH: 7.0, midpointMin: Double($0 - 2) * 45)
        }))
        let fairDrift = try #require(loose.midpointDriftMin)
        #expect(abs(fairDrift - 63.91) < 0.3)
        #expect(loose.consistencyBand == .fair)

        // A metronome schedule (all 23:30) reads zero drift — good.
        let steady = try #require(build((0..<5).map {
            night(daysAgo: $0, asleepH: 7.0, midpointMin: -30)
        }))
        let steadyDrift = try #require(steady.midpointDriftMin)
        #expect(abs(steadyDrift) < 0.001)
        #expect(steady.consistencyBand == .good)
    }

    // MARK: Stage bands wait for a norm

    /// Nine history nights alternating 19% / 21% deep with REM pinned at 25% (asleep-stage total
    /// 28 800 s each), plus a 10% deep last night.
    private var stagedHistory: [SleepReport.Night] {
        (1...9).map { d in
            let deep = d.isMultiple(of: 2) ? 6_048.0 : 5_472.0     // 21% / 19% of 28 800
            return night(daysAgo: d, asleepH: 8.0, coreS: 28_800 - deep - 7_200,
                         deepS: deep, remS: 7_200, awakeS: 600)
        }
    }
    private var lowDeepLastNight: SleepReport.Night {
        night(daysAgo: 0, asleepH: 8.0, coreS: 18_720, deepS: 2_880, remS: 7_200, awakeS: 600)
    }

    @Test func nineStageNightsShowValuesWithNoBand() throws {
        // 8 history nights + last night = 9 stage-nights: shares render, bands stay nil.
        let r = try #require(build(Array(stagedHistory.prefix(8)) + [lowDeepLastNight]))
        #expect(r.stageNightCount == 9)
        let deep = try #require(r.deepPct)
        let rem = try #require(r.remPct)
        #expect(abs(deep - 10) < 0.000_1)
        #expect(abs(rem - 25) < 0.000_1)
        #expect(r.deepBand == nil && r.remBand == nil)             // learning your norm
    }

    @Test func tenStageNightsEarnPersonalStageBands() throws {
        // Deep-% series (latest included): [10, 19×5, 21×4] → mean 18.9, SD √9.69 ≈ 3.113;
        // winsor bounds 18.9 ± 9.34 leave everything unclamped, so lower = 15.79 and last
        // night's 10% sits below the norm. REM is 25% every night (SD 0) → dead in the norm.
        let r = try #require(build(stagedHistory + [lowDeepLastNight]))
        #expect(r.stageNightCount == 10)
        #expect(r.deepBand == .belowNorm)
        #expect(r.remBand == .inNorm)
    }

    @Test func durationOnlyLastNightStaysBandlessEvenWithANorm() throws {
        // Ten staged history nights teach a norm, but last night has no stages — there is no
        // value to band, and the engine never borrows one from history.
        let tenStaged = (1...10).map { d in
            night(daysAgo: d, asleepH: 8.0, coreS: 16_128, deepS: 5_472, remS: 7_200, awakeS: 600)
        }
        let r = try #require(build(tenStaged + [night(daysAgo: 0, asleepH: 7.2)]))
        #expect(r.stageNightCount == 10)
        #expect(r.deepPct == nil && r.remPct == nil)
        #expect(r.deepBand == nil && r.remBand == nil)
    }

    // MARK: Remaining band cuts

    @Test func durationAndEfficiencyBandBoundariesMatchTheSpec() throws {
        // Duration vs the 8 h default: 7.5 → good (met within 30 min), 6.5 → fair (1.5 h short
        // is the fair floor), 6.4 → low.
        func report(asleepH: Double, inBedS: Double? = nil) throws -> SleepReport {
            try #require(build([night(daysAgo: 0, asleepH: asleepH, inBedS: inBedS)]))
        }
        #expect(try report(asleepH: 7.5).durationBand == .good)
        #expect(try report(asleepH: 6.5).durationBand == .fair)
        #expect(try report(asleepH: 6.4).durationBand == .low)

        // Efficiency vs 10 h in bed: 9 h → 90 good, 8 h → 80 fair, 7.9 h → 79 low.
        #expect(try report(asleepH: 9.0, inBedS: 36_000).efficiencyBand == .good)
        #expect(try report(asleepH: 8.0, inBedS: 36_000).efficiencyBand == .fair)
        #expect(try report(asleepH: 7.9, inBedS: 36_000).efficiencyBand == .low)

        // Union asleep can outrun a single source's in-bed record — capped at 100, never 114%.
        let capped = try report(asleepH: 8.0, inBedS: 25_200)
        #expect(capped.efficiencyPct == 100)
    }
}
