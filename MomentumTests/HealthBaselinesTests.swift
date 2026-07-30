import Testing
import Foundation
@testable import Momentum

/// Recovery Hub plan §4.1 fixtures — the personal-baseline math every other Health engine reads.
struct HealthBaselinesTests {
    /// Fixed clock + UTC calendar so day-bucketing is deterministic on any machine.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09 09:33:20 UTC
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func sample(daysAgo: Int, _ value: Double, hourOffset: Double = 0) -> (day: Date, value: Double) {
        (now.addingTimeInterval(-Double(daysAgo) * 86_400 + hourOffset * 3_600), value)
    }

    @Test func exactMeanAndSDOnThirtyKnownDays() throws {
        // 15 days at 60 and 15 at 80: mean = (15·60 + 15·80)/30 = 2100/30 = 70 exactly.
        // Every value deviates by ±10 → population variance = 30·100/30 = 100 → SD = 10 exactly.
        // Winsorization bounds = 70 ± 3·10 = [40, 100]: nothing clamps, so the pass is a no-op.
        let values = (0..<30).map { sample(daysAgo: $0, $0.isMultiple(of: 2) ? 60 : 80) }
        let b = try #require(HealthBaselines.build(from: values, windowDays: 30, now: now, calendar: cal))
        #expect(abs(b.mean - 70) < 0.000_1)
        #expect(abs(b.sd - 10) < 0.000_1)
        #expect(abs(b.lower - 60) < 0.000_1)     // mean − 1 SD
        #expect(abs(b.upper - 80) < 0.000_1)     // mean + 1 SD
        #expect(b.dayCount == 30)
        #expect(b.isBanded && b.isEstablished)
        #expect(abs(b.z(90) - 2.0) < 0.000_1)    // (90 − 70)/10
    }

    @Test func winsorizationKillsAnArtifactWithoutHidingTheTrend() throws {
        // 30 clean days alternating 95/105 (mean 100, SD 5) + one 200 artifact this morning.
        // First pass over all 31 days:
        //   mean₀ = (15·95 + 15·105 + 200)/31 = 3200/31 ≈ 103.2258
        //   Σ(x−μ₀)² = 15·(−8.2258)² + 15·(1.7742)² + (96.7742)²
        //            ≈ 1014.96     + 47.22        + 9365.24     = 10427.42
        //   SD₀ = √(10427.42/31) ≈ 18.34 → clamp ceiling = 103.2258 + 3·18.34 ≈ 158.25.
        // The artifact clamps 200 → 158.25; recomputed mean = (3000 + 158.25)/31 ≈ 101.88 —
        // a 1.88% shift vs the outlier-free 100 (< 2%). Unclamped it sat at 103.23 (3.23%),
        // so the single pass is exactly what earns the fixture's bar.
        let clean = (1...30).map { sample(daysAgo: $0, $0.isMultiple(of: 2) ? 95 : 105) }
        let control = try #require(HealthBaselines.build(from: clean, windowDays: 30, now: now, calendar: cal))
        #expect(abs(control.mean - 100) < 0.000_1)
        #expect(abs(control.sd - 5) < 0.000_1)

        let polluted = try #require(HealthBaselines.build(from: clean + [sample(daysAgo: 0, 200)],
                                                          windowDays: 30, now: now, calendar: cal))
        #expect(abs(polluted.mean - 101.879) < 0.01)                       // hand-computed above
        #expect(abs(polluted.mean - control.mean) / control.mean < 0.02)   // the fixture's bar
        #expect(polluted.mean > control.mean)                              // clamped, not deleted
    }

    @Test func bandedAtSevenDaysEstablishedAtFourteen() throws {
        func baseline(days: Int) throws -> HealthBaselines.Baseline {
            try #require(HealthBaselines.build(from: (0..<days).map { sample(daysAgo: $0, 60) },
                                               windowDays: 30, now: now, calendar: cal))
        }
        let six = try baseline(days: 6)
        #expect(!six.isBanded && !six.isEstablished)       // 6 days → no band yet
        let seven = try baseline(days: 7)
        #expect(seven.isBanded && !seven.isEstablished)    // the band arrives at 7
        let thirteen = try baseline(days: 13)
        #expect(thirteen.isBanded && !thirteen.isEstablished)
        let fourteen = try baseline(days: 14)
        #expect(fourteen.isEstablished)                    // modifiers may fire from here
        #expect(fourteen.z(100) == 0)                      // flat baseline → z guards ÷0, never NaN
    }

    @Test func multipleSamplesOnOneDayCountOnceViaTheMedian() throws {
        // Three sources wrote this morning (Watch 50, Oura 90, Whoop 70) → median 70, ONE day.
        // Daily series = [70, 80, 60] → mean 70; a triple-writing day never outvotes the others.
        let values = [
            sample(daysAgo: 0, 50, hourOffset: -3),
            sample(daysAgo: 0, 90),
            sample(daysAgo: 0, 70, hourOffset: 2),
            sample(daysAgo: 1, 80),
            sample(daysAgo: 2, 60),
        ]
        let b = try #require(HealthBaselines.build(from: values, windowDays: 30, now: now, calendar: cal))
        #expect(b.dayCount == 3)                 // 3 local days, not 5 samples
        #expect(abs(b.mean - 70) < 0.000_1)
    }

    @Test func evenSampleCountsTakeTheMidpointMedian() throws {
        // Two samples on the only day (60, 80) → median = (60 + 80)/2 = 70.
        let values = [sample(daysAgo: 0, 60), sample(daysAgo: 0, 80, hourOffset: 1)]
        let b = try #require(HealthBaselines.build(from: values, windowDays: 30, now: now, calendar: cal))
        #expect(b.dayCount == 1)
        #expect(abs(b.mean - 70) < 0.000_1)
        #expect(b.sd == 0)                       // one daily value → no spread
    }

    @Test func windowCutsOffAtDayThirtyOne() throws {
        // 30-day window: a value from exactly 30 days ago is still "within 30 days" and counts;
        // day 31 is the cutoff. Every in-window day reads 60; day 31 carries a 1000 that would
        // drag the mean up (even winsorized) if it leaked — an exact mean of 60 proves the cut.
        let values = (0...30).map { sample(daysAgo: $0, 60) } + [sample(daysAgo: 31, 1_000)]
        let b = try #require(HealthBaselines.build(from: values, windowDays: 30, now: now, calendar: cal))
        #expect(b.dayCount == 31)                // today + the 30 trailing days
        #expect(abs(b.mean - 60) < 0.000_1)
    }

    @Test func emptyStaleOrFutureHistoryIsNil() {
        #expect(HealthBaselines.build(from: [], windowDays: 30, now: now, calendar: cal) == nil)
        // Everything outside the window (too old, or future-dated junk) → nil, never a fake norm.
        let stale = [sample(daysAgo: 45, 60), sample(daysAgo: -2, 60)]
        #expect(HealthBaselines.build(from: stale, windowDays: 30, now: now, calendar: cal) == nil)
    }

    @Test func signalWindowsMatchTheSpec() {
        // §4.1: HRV 30d · RHR 30d · respiratory 30d · wrist temp 60d · walking HR 60d.
        #expect(HealthBaselines.Window.hrv == 30)
        #expect(HealthBaselines.Window.restingHR == 30)
        #expect(HealthBaselines.Window.respiratoryRate == 30)
        #expect(HealthBaselines.Window.wristTemperature == 60)
        #expect(HealthBaselines.Window.walkingHR == 60)
    }
}
