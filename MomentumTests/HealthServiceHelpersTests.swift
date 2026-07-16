import Testing
import Foundation
@testable import Momentum

/// The pure day-bucketed reductions behind the Health hub's history reads (RECOVERY-HUB-PLAN §3):
/// per-day medians for vitals, per-source-max for steps, the sleep union-merge + night bucketing,
/// the single-best-source stage rule, and ambient netting. All HealthKit-free — these helpers take
/// plain tuples so the multi-source rules are testable without a store.
struct HealthServiceHelpersTests {

    /// Fixed UTC calendar so day boundaries don't drift with the machine's timezone.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-07-01 UTC + `day` days, at `hour:minute`.
    private func at(day: Int = 0, _ hour: Int, _ minute: Int = 0) -> Date {
        DateComponents(calendar: cal, timeZone: cal.timeZone,
                       year: 2026, month: 7, day: 1 + day, hour: hour, minute: minute).date!
    }

    private func day(_ n: Int) -> Date { cal.startOfDay(for: at(day: n, 12)) }

    // MARK: Median per day (vitals)

    @Test func medianIsRobustToASpotCheckSpike() {
        // Two honest overnight readings + one daytime artifact — the median ignores the spike
        // where a mean would drag the baseline up.
        let out = HealthService.medianPerDay([
            (date: at(day: 0, 6), value: 52),
            (date: at(day: 0, 7), value: 55),
            (date: at(day: 0, 12), value: 200),
            (date: at(day: 1, 6), value: 58),
        ], calendar: cal)
        #expect(out.count == 2)
        #expect(out[0] == (day: day(0), value: 55))
        #expect(out[1] == (day: day(1), value: 58))     // sorted ascending
    }

    @Test func evenCountMedianAveragesTheMiddleTwo() {
        let out = HealthService.medianPerDay([
            (date: at(day: 0, 6), value: 40),
            (date: at(day: 0, 8), value: 60),
        ], calendar: cal)
        #expect(out.count == 1)
        #expect(out[0] == (day: day(0), value: 50))
        #expect(HealthService.medianPerDay([], calendar: cal).isEmpty)
    }

    // MARK: Max across sources (steps)

    @Test func stepsTakeTheMaxSourceNeverTheCrossSourceSum() {
        // Watch counted 8 000 across two chunks; the phone (in a pocket part of the day) saw 5 000
        // of the same strides. The honest day is 8 000 — a cumulative sum would say 13 000.
        let out = HealthService.maxSourceSumPerDay([
            (date: at(day: 0, 9), value: 6_000, source: "watch"),
            (date: at(day: 0, 17), value: 2_000, source: "watch"),
            (date: at(day: 0, 12), value: 5_000, source: "phone"),
        ], calendar: cal)
        #expect(out.count == 1)
        #expect(out[0] == (day: day(0), value: 8_000))
    }

    @Test func maxSourceIsPickedPerDayIndependently() {
        let out = HealthService.maxSourceSumPerDay([
            (date: at(day: 0, 9), value: 9_000, source: "watch"),
            (date: at(day: 0, 9), value: 4_000, source: "phone"),
            (date: at(day: 1, 9), value: 1_000, source: "watch"),   // watch barely worn day 2
            (date: at(day: 1, 9), value: 7_000, source: "phone"),
        ], calendar: cal)
        #expect(out.count == 2)
        #expect(out[0] == (day: day(0), value: 9_000))
        #expect(out[1] == (day: day(1), value: 7_000))
    }

    // MARK: Union merge (the shipped sleep rule, extracted)

    @Test func overlappingSourcesCountEveryMinuteOnce() {
        // Watch 23:00–07:00, ring 23:30–07:15 — the same night twice. Union: 23:00–07:15.
        let union = HealthService.unionSeconds([
            (start: at(day: 0, 23), end: at(day: 1, 7)),
            (start: at(day: 0, 23, 30), end: at(day: 1, 7, 15)),
        ])
        #expect(union == 8.25 * 3600)
    }

    @Test func abuttingSpansMergeAndDisjointSpansSum() {
        let abutting = HealthService.mergedSpans([
            (start: at(day: 0, 10), end: at(day: 0, 11)),
            (start: at(day: 0, 11), end: at(day: 0, 12)),
        ])
        #expect(abutting.count == 1)
        #expect(abutting[0].start == at(day: 0, 10) && abutting[0].end == at(day: 0, 12))

        let disjoint = HealthService.unionSeconds([
            (start: at(day: 0, 10), end: at(day: 0, 11)),
            (start: at(day: 0, 14), end: at(day: 0, 15)),
        ])
        #expect(disjoint == 2 * 3600)
    }

    // MARK: Night bucketing

    @Test func nightsBelongToTheMorningTheyEnded() {
        // Wake-up segment → that day; pre-midnight bedtime → the NEXT morning (same night).
        #expect(HealthService.nightKey(for: at(day: 1, 7), calendar: cal) == day(1))
        #expect(HealthService.nightKey(for: at(day: 0, 23, 40), calendar: cal) == day(1))
        // An afternoon nap folds into the morning it followed; 15:00 is the early-bedtime boundary
        // (mirroring the shipped 18-hour lookback).
        #expect(HealthService.nightKey(for: at(day: 1, 14, 59), calendar: cal) == day(1))
        #expect(HealthService.nightKey(for: at(day: 1, 15), calendar: cal) == day(2))
    }

    @Test func nightSpanIsTheOuterWindowAcrossSources() {
        let nights = HealthService.nightSpans(from: [
            .init(start: at(day: 0, 23), end: at(day: 1, 3), kind: .asleep, source: "watch"),
            .init(start: at(day: 0, 23, 30), end: at(day: 1, 7, 15), kind: .core, source: "ring"),
            .init(start: at(day: 1, 6), end: at(day: 1, 6, 20), kind: .awake, source: "ring"),  // awake ≠ asleep
        ], calendar: cal)
        #expect(nights.count == 1)
        #expect(nights[day(1)]?.start == at(day: 0, 23))
        #expect(nights[day(1)]?.end == at(day: 1, 7, 15))
    }

    // MARK: HRV night preference (§11.2.5)

    @Test func hrvMedianPrefersOvernightSamples() {
        // Three overnight readings + a post-espresso daytime spot-check. With the night window
        // present, the spot-check is excluded; the pre-midnight reading lands on the morning it
        // served, not the calendar day it was taken.
        let nights = [day(1): (start: at(day: 0, 23), end: at(day: 1, 7))]
        let out = HealthService.nightPreferredMedianPerDay([
            (date: at(day: 0, 23, 30), value: 60),
            (date: at(day: 1, 2), value: 64),
            (date: at(day: 1, 6), value: 68),
            (date: at(day: 1, 11), value: 95),
        ], nights: nights, calendar: cal)
        #expect(out.count == 1)
        #expect(out[0] == (day: day(1), value: 64))
    }

    @Test func hrvFallsBackToAllDayWhenNoSleepWasRecorded() {
        let out = HealthService.nightPreferredMedianPerDay([
            (date: at(day: 1, 2), value: 64),
            (date: at(day: 1, 11), value: 95),
        ], nights: [:], calendar: cal)
        #expect(out.count == 1)
        #expect(out[0] == (day: day(1), value: 79.5))
    }

    // MARK: Night reports (sleepNights assembly)

    @Test func singleSourceNightReportsExactStageDurations() throws {
        let nights = HealthService.nightReports(from: [
            .init(start: at(day: 0, 23), end: at(day: 1, 2), kind: .core, source: "watch"),
            .init(start: at(day: 1, 2), end: at(day: 1, 3), kind: .deep, source: "watch"),
            .init(start: at(day: 1, 3), end: at(day: 1, 4), kind: .rem, source: "watch"),
            .init(start: at(day: 1, 4), end: at(day: 1, 4, 10), kind: .awake, source: "watch"),
            .init(start: at(day: 1, 4, 10), end: at(day: 1, 6, 40), kind: .core, source: "watch"),
        ], calendar: cal)
        #expect(nights.count == 1)
        let n = try #require(nights.first)
        #expect(n.date == day(1))
        #expect(n.asleepH == 7.5)                       // the 10-min awake gap doesn't count
        #expect(n.coreS == 5.5 * 3600)
        #expect(n.deepS == 3600)
        #expect(n.remS == 3600)
        #expect(n.awakeS == 600)
        #expect(n.inBedS == nil)
    }

    @Test func stagesComeFromTheSingleLargestStageSourceDurationFromTheUnion() throws {
        // Ring wrote 8 h of stages, watch 6 h — the ring's stages win whole; the watch's REM must
        // never splice in (cross-source stage unions produce impossible nights). Duration still
        // union-merges both.
        let nights = HealthService.nightReports(from: [
            .init(start: at(day: 0, 23), end: at(day: 1, 7), kind: .core, source: "ring"),
            .init(start: at(day: 0, 23, 30), end: at(day: 1, 5, 30), kind: .rem, source: "watch"),
        ], calendar: cal)
        let n = try #require(nights.first)
        #expect(n.asleepH == 8)                          // union 23:00–07:00
        #expect(n.coreS == 8.0 * 3600)                   // ring's breakdown, whole (Double literal — an Int expression falls into cross-type AnyHashable ==, which is false even for equal values)
        #expect(n.remS == 0)                             // watch's REM did not splice in
    }

    @Test func longerDurationOnlySourceCannotBlankOutRealStages() throws {
        // Garmin wrote 8 h of unspecified sleep; the watch wrote 6 h WITH stages. Duration is the
        // union (Garmin's longer night counts), but the stage breakdown survives from the watch.
        let nights = HealthService.nightReports(from: [
            .init(start: at(day: 0, 22, 50), end: at(day: 1, 6, 50), kind: .asleep, source: "garmin"),
            .init(start: at(day: 0, 23, 30), end: at(day: 1, 5, 30), kind: .core, source: "watch"),
        ], calendar: cal)
        let n = try #require(nights.first)
        #expect(n.asleepH == 8)
        #expect(n.coreS == 6.0 * 3600)
    }

    @Test func durationOnlyNightReportsNilStages() throws {
        let nights = HealthService.nightReports(from: [
            .init(start: at(day: 0, 23), end: at(day: 1, 6), kind: .asleep, source: "garmin"),
        ], calendar: cal)
        let n = try #require(nights.first)
        #expect(n.asleepH == 7)
        #expect(n.coreS == nil && n.deepS == nil && n.remS == nil && n.awakeS == nil)
    }

    @Test func inBedOnlyNightSurvivesWithNoAsleepDuration() throws {
        // Phone-only bedtime tracking: the night exists (the UI can say "in bed 8h 20m"), but there
        // is no asleep duration to pretend about.
        let nights = HealthService.nightReports(from: [
            .init(start: at(day: 0, 22, 45), end: at(day: 1, 7, 5), kind: .inBed, source: "phone"),
        ], calendar: cal)
        let n = try #require(nights.first)
        #expect(n.asleepH == 0)
        #expect(n.inBedS == Double((8 * 60 + 20) * 60))
        #expect(n.coreS == nil)
    }

    @Test func twoNightsBucketAndSortSeparately() {
        let nights = HealthService.nightReports(from: [
            .init(start: at(day: 1, 23), end: at(day: 2, 6), kind: .asleep, source: "watch"),
            .init(start: at(day: 0, 23), end: at(day: 1, 7), kind: .asleep, source: "watch"),
        ], calendar: cal)
        #expect(nights.map(\.date) == [day(1), day(2)])
        #expect(nights.map(\.asleepH) == [8, 7])
    }

    // MARK: Ambient netting (DayStrain input)

    @Test func noWorkoutMeansEverythingIsAmbient() {
        let sum = HealthService.ambientSum([
            (start: at(day: 0, 9), end: at(day: 0, 9, 30), value: 400, source: "phone"),
            (start: at(day: 0, 10), end: at(day: 0, 10, 30), value: 600, source: "phone"),
        ], nettingOut: [])
        #expect(sum == 1_000)
    }

    @Test func workoutWindowIsNettedOutProRata() {
        // The 10:00–10:30 chunk is fully inside the run; the 11:00–11:30 chunk overlaps its last
        // 15 min → half its steps stay ambient.
        let sum = HealthService.ambientSum([
            (start: at(day: 0, 10), end: at(day: 0, 10, 30), value: 3_000, source: "watch"),
            (start: at(day: 0, 11), end: at(day: 0, 11, 30), value: 600, source: "watch"),
            (start: at(day: 0, 15), end: at(day: 0, 15, 30), value: 500, source: "watch"),
        ], nettingOut: [(start: at(day: 0, 10), end: at(day: 0, 11, 15))])
        #expect(sum == 800)                              // 0 + 300 + 500
    }

    @Test func nettingAppliesPerSourceBeforeTheMax() {
        // Watch: 5 000 total, 4 000 inside the run → 1 000 ambient. Phone stayed home: 800 ambient.
        // The day's ambient is max(1 000, 800), not the un-netted watch total.
        let sum = HealthService.ambientSum([
            (start: at(day: 0, 10), end: at(day: 0, 10, 40), value: 4_000, source: "watch"),
            (start: at(day: 0, 15), end: at(day: 0, 15, 30), value: 1_000, source: "watch"),
            (start: at(day: 0, 12), end: at(day: 0, 12, 30), value: 800, source: "phone"),
        ], nettingOut: [(start: at(day: 0, 10), end: at(day: 0, 10, 40))])
        #expect(sum == 1_000)
    }

    @Test func instantaneousSamplesAreAllInOrAllOut() {
        let spans = [(start: at(day: 0, 10), end: at(day: 0, 10, 30))]
        let inside = HealthService.ambientSum(
            [(start: at(day: 0, 10, 5), end: at(day: 0, 10, 5), value: 100, source: "phone")],
            nettingOut: spans)
        let outside = HealthService.ambientSum(
            [(start: at(day: 0, 11), end: at(day: 0, 11), value: 100, source: "phone")],
            nettingOut: spans)
        #expect(inside == 0)                             // clamped, never negative
        #expect(outside == 100)
    }

    @Test func noSamplesMeansAbsentNeverZero() {
        #expect(HealthService.ambientSum([], nettingOut: []) == nil)
    }
}

/// The `RecoverySignals` illness-watch extension (RECOVERY-HUB-PLAN §11.1.3) — new optional fields
/// stay nil by default (existing call sites unchanged), and the strained demo reads as a morning
/// that should ease today's session.
struct RecoverySignalsIllnessWatchTests {

    @Test func newFieldsDefaultNilAndExistingInitializersCompileUnchanged() {
        let s = RecoverySignals(hrvMs: 68, hrvBaselineMs: 63)   // pre-existing call-site shape
        #expect(s.respiratoryZ == nil)
        #expect(s.wristTempDeltaC == nil)
        #expect(RecoverySignals.empty.respiratoryZ == nil)
    }

    @Test func demoStrainedIsAConcordantStrainedMorning() {
        let s = RecoverySignals.demoStrained
        #expect(s.hrvTrend == .down)                     // HRV well below norm
        #expect(s.restingHRNote == "elevated")
        #expect(s.sleepNote == "short")
        #expect(s.respiratoryZ == 2.1)
        #expect(s.wristTempDeltaC == 0.6)
        #expect(s.blendedReadiness(base: 70) < 45)       // reads strained, not moderate
    }
}
