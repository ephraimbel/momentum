import Testing
import Foundation
@testable import Momentum

/// The athlete state derived from logged runs (`AthleteStateEngine`): the personal fatigue
/// exponent, the threshold proxy by method, the durability read, and the planner's three-way
/// summary of it. Every fixture is hand-built so the expected numbers are on the page.
struct AthleteStateEngineTests {

    private let asOf = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let cal = Calendar(identifier: .gregorian)

    private func day(_ daysAgo: Int) -> Date { cal.date(byAdding: .day, value: -daysAgo, to: asOf)! }

    /// A run at a flat pace, optionally with even splits carrying a heart rate that drifts up by
    /// `hrDrift` fraction across the run (pace held).
    private func run(daysAgo: Int, km: Double, paceSPerKm: Double, rpe: Int? = nil,
                     planned: RunType? = nil, plannedKm: Double? = nil, isRace: Bool = false,
                     hr: Int? = nil, hrDrift: Double = 0, planFit: PlanFit? = nil) -> RunEvidenceRow {
        var row = RunEvidenceRow(startedAt: day(daysAgo), distanceM: km * 1000, durationS: km * paceSPerKm,
                                 rpe: rpe, plannedRunType: planned, plannedDistanceM: plannedKm.map { $0 * 1000 },
                                 planFit: planFit, isRace: isRace)
        if let hr {
            row.avgHR = hr
            let n = max(6, Int(km))
            row.splits = (0..<n).map { i in
                let f = Double(i) / Double(max(1, n - 1))
                return .init(distanceM: km * 1000 / Double(n), durationS: km * paceSPerKm / Double(n),
                             avgHR: Int((Double(hr) * (1 + hrDrift * f)).rounded()))
            }
        }
        return row
    }

    // MARK: Personal Riegel exponent

    @Test func exponentIsFittedFromTwoRacesAtDifferentDistances() {
        // A durable athlete: 5K in 20:00, half in 1:29:00 → k ≈ log(5340/1200)/log(21097/5000) ≈ 1.037.
        let state = AthleteStateEngine.derive(runs: [
            run(daysAgo: 30, km: 5, paceSPerKm: 240, isRace: true),
            run(daysAgo: 10, km: 21.097, paceSPerKm: 5340 / 21.097, isRace: true),
        ], asOf: asOf, calendar: cal)
        let curve = try! #require(state.performanceCurve)
        let k = try! #require(curve.value.riegelExponent)
        #expect(abs(k - 1.037) < 0.01)
        #expect(curve.confidence == .high)
        #expect(curve.source == .raceResult)
        #expect(curve.value.points.count == 2)
    }

    @Test func exponentIsBoundedAndNeedsSpread() {
        // Two efforts too close in distance say nothing about fatigue.
        #expect(AthleteStateEngine.fitRiegelExponent([
            .init(distanceM: 5_000, durationS: 1_200, paceSPerKm: 240),
            .init(distanceM: 6_000, durationS: 1_500, paceSPerKm: 250),
        ]) == nil)
        // A 5K sandbagged next to a fast half would imply k < 1 — clamped to the floor, not believed.
        let low = AthleteStateEngine.fitRiegelExponent([
            .init(distanceM: 5_000, durationS: 1_500, paceSPerKm: 300),
            .init(distanceM: 21_097, durationS: 5_000, paceSPerKm: 237),
        ])
        #expect(low == AthleteStateEngine.riegelExponentBounds.lowerBound)
        // A fade far beyond physiology is clamped to the ceiling.
        let high = AthleteStateEngine.fitRiegelExponent([
            .init(distanceM: 5_000, durationS: 1_200, paceSPerKm: 240),
            .init(distanceM: 42_195, durationS: 16_000, paceSPerKm: 379),
        ])
        #expect(high == AthleteStateEngine.riegelExponentBounds.upperBound)
    }

    @Test func singleEffortKeepsThePopulationExponentAndSaysSo() {
        let state = AthleteStateEngine.derive(runs: [run(daysAgo: 5, km: 5, paceSPerKm: 240, isRace: true)],
                                              asOf: asOf, calendar: cal)
        let curve = try! #require(state.performanceCurve)
        #expect(curve.value.riegelExponent == nil)
        #expect(curve.limitations.contains(.smallSample))
        #expect(curve.confidence == .low)
        // …and the planner seed falls back to the population value.
        let seed = AthleteStateEngine.seed(.none, with: state)
        #expect(seed.riegelExponent == nil)
    }

    @Test func tempoRunsDoNotOutrankRacesInTheCurve() {
        // A slow tempo at 10K distance must not sit on the curve when a real 10K race exists.
        let state = AthleteStateEngine.derive(runs: [
            run(daysAgo: 20, km: 5, paceSPerKm: 240, isRace: true),
            run(daysAgo: 15, km: 10, paceSPerKm: 275, planned: .tempo),
            run(daysAgo: 8, km: 10, paceSPerKm: 250, isRace: true),
        ], asOf: asOf, calendar: cal)
        let points = state.performanceCurve!.value.points
        #expect(points.count == 2)
        #expect(points.contains { abs($0.paceSPerKm - 250) < 0.01 })
        #expect(!points.contains { abs($0.paceSPerKm - 275) < 0.01 })
    }

    // MARK: Threshold proxy

    @Test func anHourRaceIsTheThresholdOutright() {
        // 15 km in 60:00 → T = 240 s/km, high confidence, race method.
        let state = AthleteStateEngine.derive(runs: [run(daysAgo: 6, km: 15, paceSPerKm: 240, isRace: true)],
                                              asOf: asOf, calendar: cal)
        let t = try! #require(state.thresholdProxy)
        #expect(t.value.paceSPerKm == 240)
        #expect(t.value.method == .raceResult)
        #expect(t.confidence == .high)
        #expect(t.limitations.isEmpty)
    }

    @Test func aShorterRaceIsMovedAlongTheCurveToAnHour() {
        // 10K race in 40:00 (240 s/km). At k = 1.06 the hour distance is 10 km·(60/40)^(1/1.06)
        // ≈ 14.66 km → T ≈ 245 s/km: slower than the 10K pace, as it must be.
        let state = AthleteStateEngine.derive(runs: [run(daysAgo: 6, km: 10, paceSPerKm: 240, isRace: true)],
                                              asOf: asOf, calendar: cal)
        let t = try! #require(state.thresholdProxy)
        #expect((t.value.paceSPerKm ?? 0) > 240 && (t.value.paceSPerKm ?? 0) < 250)
        #expect(t.limitations.contains(.outsideObservedDuration))
        #expect(t.confidence == .moderate)
    }

    @Test func heartRateBlockGivesAWorkoutEstimate() {
        // Max 190, rest 50: 86–92 % HRR = 170–179 bpm. A 40-minute run whose middle splits sit at
        // 174 bpm at 250 s/km, easy splits either side at 140 bpm.
        var row = RunEvidenceRow(startedAt: day(4), distanceM: 9_600, durationS: 40 * 60)
        row.splits = (0..<10).map { i in
            let inBand = (2...7).contains(i)
            return .init(distanceM: inBand ? 1_000 : 900, durationS: inBand ? 250 : 270, avgHR: inBand ? 174 : 140)
        }
        // A block of six splits × 250 s = 25 min at threshold HR.
        let state = AthleteStateEngine.derive(runs: [row], profile: .init(maxHR: 190, restingHR: 50),
                                              asOf: asOf, calendar: cal)
        let t = try! #require(state.thresholdProxy)
        #expect(t.value.method == .workoutEstimate)
        #expect(t.value.paceSPerKm == 250)
        #expect(t.value.heartRateBPM == 174)
        #expect(t.confidence == .moderate)
    }

    @Test func completedSteadySessionsGiveAMedianAndFlagMissingRPE() {
        let state = AthleteStateEngine.derive(runs: [
            run(daysAgo: 20, km: 8, paceSPerKm: 262, rpe: 7, planned: .tempo),
            run(daysAgo: 12, km: 8, paceSPerKm: 258, planned: .tempo),
            run(daysAgo: 4, km: 8, paceSPerKm: 254, rpe: 7, planned: .tempo),
        ], asOf: asOf, calendar: cal)
        let t = try! #require(state.thresholdProxy)
        #expect(t.value.paceSPerKm == 258)
        #expect(t.value.method == .workoutEstimate)
        #expect(t.confidence == .low)
        #expect(t.limitations == [.missingRPE])
    }

    @Test func easyRunningNeverProducesAThreshold() {
        let state = AthleteStateEngine.derive(runs: [
            run(daysAgo: 20, km: 10, paceSPerKm: 330, planned: .easy),
            run(daysAgo: 12, km: 16, paceSPerKm: 340, planned: .long),
            run(daysAgo: 4, km: 8, paceSPerKm: 335, rpe: 3, planned: .easy),
        ], asOf: asOf, calendar: cal)
        #expect(state.thresholdProxy == nil)
        #expect(state.performanceCurve == nil)
    }

    // MARK: Durability

    @Test func finishedLongRunsWithFlatDriftReadStrong() {
        var runs: [RunEvidenceRow] = []
        for i in 0..<4 {
            runs.append(run(daysAgo: 7 * i + 3, km: 18, paceSPerKm: 330, planned: .long, plannedKm: 18,
                            hr: 145, hrDrift: 0.02))
        }
        let state = AthleteStateEngine.derive(runs: runs, asOf: asOf, calendar: cal)
        let d = try! #require(state.durability)
        #expect(d.value.completionFraction == 1)
        #expect(d.value.lateSessionResponse == .stable)
        #expect(d.value.observedDurationS == 18 * 330)
        #expect(d.confidence == .high)
        #expect(AthleteStateEngine.durabilitySignal(state.durability) == .strong)
    }

    @Test func fadingLateInLongRunsReadsFragile() {
        var runs: [RunEvidenceRow] = []
        for i in 0..<3 {
            runs.append(run(daysAgo: 7 * i + 3, km: 18, paceSPerKm: 330, planned: .long, plannedKm: 18,
                            hr: 145, hrDrift: 0.15))
        }
        let state = AthleteStateEngine.derive(runs: runs, asOf: asOf, calendar: cal)
        #expect(state.durability?.value.lateSessionResponse == .declining)
        #expect(AthleteStateEngine.durabilitySignal(state.durability) == .fragile)
    }

    @Test func cuttingLongRunsShortReadsFragileWithoutHeartRate() {
        let runs = [
            run(daysAgo: 24, km: 12, paceSPerKm: 330, planned: .long, plannedKm: 18),
            run(daysAgo: 17, km: 18, paceSPerKm: 330, planned: .long, plannedKm: 18, planFit: .harder),
            run(daysAgo: 10, km: 18, paceSPerKm: 330, planned: .long, plannedKm: 18),
            run(daysAgo: 3, km: 13, paceSPerKm: 330, planned: .long, plannedKm: 18),
        ]
        let state = AthleteStateEngine.derive(runs: runs, asOf: asOf, calendar: cal)
        let d = try! #require(state.durability)
        #expect(d.value.completionFraction == 0.25)
        #expect(d.value.lateSessionResponse == .indeterminate)
        #expect(d.limitations.contains(.missingEnvironment))
        #expect(AthleteStateEngine.durabilitySignal(state.durability) == .fragile)
    }

    @Test func nothingToSayIsNil() {
        // Two easy runs, no plan, no heart rate: durability exists (a longest run) but carries no
        // read the planner should act on.
        let state = AthleteStateEngine.derive(runs: [
            run(daysAgo: 9, km: 6, paceSPerKm: 340), run(daysAgo: 2, km: 7, paceSPerKm: 335),
        ], asOf: asOf, calendar: cal)
        #expect(AthleteStateEngine.durabilitySignal(state.durability) == nil)
        #expect(AthleteStateEngine.derive(runs: [], asOf: asOf, calendar: cal).durability == nil)
    }

    @Test func cardiacDriftIsSpeedPerBeatFirstThirdVersusLast() {
        let flat = run(daysAgo: 1, km: 12, paceSPerKm: 300, hr: 150, hrDrift: 0)
        #expect(abs(AthleteStateEngine.cardiacDrift(flat) ?? 1) < 0.001)
        let drifting = run(daysAgo: 1, km: 12, paceSPerKm: 300, hr: 150, hrDrift: 0.10)
        let d = try! #require(AthleteStateEngine.cardiacDrift(drifting))
        #expect(d > 0.05 && d < 0.10)
        #expect(AthleteStateEngine.cardiacDrift(run(daysAgo: 1, km: 12, paceSPerKm: 300)) == nil)
    }

    // MARK: The window and the seed

    @Test func evidenceOutsideEightWeeksIsIgnored() {
        let state = AthleteStateEngine.derive(runs: [run(daysAgo: 70, km: 15, paceSPerKm: 240, isRace: true)],
                                              asOf: asOf, calendar: cal)
        #expect(state.thresholdProxy == nil)
        #expect(state.longestRecentRunM == nil)
    }

    @Test func seedFillsOnlyWhatOnboardingLeftEmpty() {
        let state = AthleteStateEngine.derive(runs: [
            run(daysAgo: 30, km: 5, paceSPerKm: 240, isRace: true),
            run(daysAgo: 6, km: 15, paceSPerKm: 245, isRace: true),
        ], asOf: asOf, calendar: cal)
        var explicit = CalibrationSeed.none
        explicit.thresholdSPerKm = 230
        let seeded = AthleteStateEngine.seed(explicit, with: state)
        #expect(seeded.thresholdSPerKm == 230)          // the athlete's own entry stands
        #expect(seeded.riegelExponent != nil)           // the curve filled the empty field
        let fresh = AthleteStateEngine.seed(.none, with: state)
        #expect(fresh.thresholdSPerKm == 245)
    }
}
