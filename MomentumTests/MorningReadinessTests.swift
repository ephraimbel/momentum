import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Recovery Hub plan §4.2 fixtures — the morning blend, its renormalized pillars, the
/// illness-watch modifiers, and band parity with `RecoveryModel` (one banding function app-wide).
@MainActor
struct MorningReadinessTests {

    // MARK: Fixtures

    private func run(daysAgo: Int, minutes: Double) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        w.durationS = minutes * 60
        return w
    }

    /// A steady varied month (every 3rd day, 4 weeks) — no RecoveryModel deduction fires
    /// (ACWR ≈ 1.09, monotony ≈ 0.87, rest days present), so `score` is exactly 100. This is the
    /// same pattern RecoveryModelTests pins as primed.
    private var strongLoad: RecoveryModel {
        RecoveryModel(workouts: stride(from: 0, through: 27, by: 3).map { run(daysAgo: $0, minutes: 40) })
    }

    /// The 7-day grind — RecoveryModelTests pins this at exactly 60 (−25 monotony, −15 no-rest).
    private var grindLoad: RecoveryModel {
        RecoveryModel(workouts: (0..<7).map { run(daysAgo: $0, minutes: 45) })
    }

    private func baseline(_ mean: Double, sd: Double, days: Int = 30) -> HealthBaselines.Baseline {
        HealthBaselines.Baseline(mean: mean, sd: sd, dayCount: days, windowDays: 30)
    }

    /// The golden morning (hand-computed in `goldenMorningHandComputed`), with per-pillar
    /// overrides for the perturbation tests. Baselines: HRV 60±5, resting HR 50±2, both banded.
    private func morning(load: RecoveryModel?,
                         hrv: Double? = 65,
                         rhr: Int? = 48,
                         sleep: Double? = 7.5,
                         respiratoryZ: Double? = nil,
                         wristTempDeltaC: Double? = nil,
                         checkin: DailyCheckin? = DailyCheckin(energy: .full, legs: .fresh)) -> MorningReadiness? {
        MorningReadiness(load: load,
                         signals: RecoverySignals(hrvMs: hrv, restingHR: rhr, sleepHours: sleep,
                                                  respiratoryZ: respiratoryZ, wristTempDeltaC: wristTempDeltaC),
                         hrvBaseline: baseline(60, sd: 5),
                         restingHRBaseline: baseline(50, sd: 2),
                         sleepDebt14H: 1.0,
                         checkin: checkin)
    }

    // MARK: The headline fixtures

    @Test func zeroPillarsMeansNilNeverAFakeNumber() {
        // Nothing present at all → nil ("learning you"), never an invented number.
        #expect(MorningReadiness(load: nil, signals: .empty) == nil)
        // A month-less athlete (hasData == false) contributes no load pillar.
        #expect(MorningReadiness(load: RecoveryModel(workouts: []), signals: .empty) == nil)
        // Modifiers alone can't invent a score either.
        #expect(MorningReadiness(signals: RecoverySignals(respiratoryZ: 2.5, wristTempDeltaC: 1.5)) == nil)
    }

    @Test func allNeutralPillarsReadFiftyModerate() throws {
        // Every present pillar dead neutral: HRV 60 vs 60±5 → z = 0 → 50 · resting HR 50 vs
        // 50±2 → z = 0 → 50 · sleep 6 h vs 8 h need → 100 − 25·2 = 50. Three 50s blend to 50.
        let r = try #require(MorningReadiness(signals: RecoverySignals(hrvMs: 60, restingHR: 50, sleepHours: 6),
                                              hrvBaseline: baseline(60, sd: 5),
                                              restingHRBaseline: baseline(50, sd: 2)))
        #expect(r.score == 50)
        #expect(r.band == .moderate)
        #expect(r.confidence == .low)                                    // 3 of 5 pillars
        #expect(r.pillars.allSatisfy { abs($0.score - 50) < 0.000_1 })
        #expect(abs(r.pillars.reduce(0) { $0 + $1.points }) < 0.000_1)   // Σ points = blend − 50 = 0
    }

    @Test func goldenMorningHandComputed() throws {
        // All five pillars:
        //   load      100 (strongLoad, verbatim)                      × .30 → 30.0
        //   HRV        70 (65 vs 60±5 → z = +1 → 50 + 20)             × .25 → 17.5
        //   sleep      85 (7.5 h vs 8 h need → −12.5; 1 h debt → −2.5) × .20 → 17.0
        //   restingHR  70 (48 vs 50±2 → z = −1, inverted → 50 + 20)   × .15 → 10.5
        //   check-in  100 (full tank +20, fresh legs +20 → 60 + 40)   × .10 → 10.0
        // blend = 85 → score 85, primed, full confidence, no modifiers.
        let r = try #require(morning(load: strongLoad))
        #expect(r.score == 85)
        #expect(r.band == .primed)
        #expect(r.confidence == .high)
        #expect(r.modifiers.isEmpty && r.modifierPoints == 0)
        #expect(abs(r.blend - 85) < 0.000_1)
        #expect(r.guidance == RecoveryModel.guidance(.primed))

        // Per-pillar contributions (points = weight·(score − 50)) — the DriverRow's numbers:
        // load .30·50 = 15 · HRV .25·20 = 5 · sleep .20·35 = 7 · RHR .15·20 = 3 · check-in .10·50 = 5.
        #expect(r.pillars.map(\.kind) == [.load, .hrv, .sleep, .restingHR, .checkin])
        for (got, want) in zip(r.pillars.map(\.points), [15.0, 5, 7, 3, 5]) {
            #expect(abs(got - want) < 0.000_1)
        }
        // The DriverRow identity: Σ points = blend − 50.
        #expect(abs(r.pillars.reduce(0) { $0 + $1.points } - (r.blend - 50)) < 0.000_001)
    }

    @Test func renormalizationIsExactOverPresentPillars() throws {
        // Load + check-in only: weights renormalize to .30/.40 = 0.75 and .10/.40 = 0.25, i.e.
        // blend = (0.30·L + 0.10·C)/0.40 — §4.2's exactness fixture.
        //   L = 60 (the pinned grind score) · C = 60 − 25 (drained) − 20 (heavy legs) = 15
        //   blend = 0.75·60 + 0.25·15 = 45 + 3.75 = 48.75 → rounds to 49, moderate.
        let r = try #require(MorningReadiness(load: grindLoad,
                                              checkin: DailyCheckin(energy: .low, legs: .heavy)))
        #expect(r.pillars.count == 2)
        #expect(abs(r.pillars[0].weight - 0.75) < 0.000_000_1)
        #expect(abs(r.pillars[1].weight - 0.25) < 0.000_000_1)
        #expect(abs(r.blend - (0.30 * 60 + 0.10 * 15) / 0.40) < 0.000_001)
        #expect(r.score == 49)
        #expect(r.band == .moderate)
        // Σ points = blend − 50 holds under renormalization too.
        #expect(abs(r.pillars.reduce(0) { $0 + $1.points } - (r.blend - 50)) < 0.000_001)
    }

    @Test func watchLessMorningStillScoresAtMinimalConfidence() throws {
        // No wearable at all — training history + this morning's check-in still make a real
        // number: 0.75·60 + 0.25·60 = 60, moderate, minimal confidence. Day one is never blank.
        let r = try #require(MorningReadiness(load: grindLoad,
                                              checkin: DailyCheckin(energy: .ok, legs: .ok)))
        #expect(r.score == 60)
        #expect(r.band == .moderate)
        #expect(r.confidence == .minimal)                                // 2 pillars

        // Even a check-in alone scores — its weight renormalizes to 1.
        let solo = try #require(MorningReadiness(checkin: DailyCheckin(energy: .ok, legs: .ok)))
        #expect(solo.pillars.count == 1)
        #expect(abs(solo.pillars[0].weight - 1.0) < 0.000_000_1)
        #expect(solo.score == 60)                                        // 60 + 0 + 0, verbatim
        #expect(solo.confidence == .minimal)

        // A passed-but-empty load model (hasData == false) never sneaks in as a pillar.
        let noHistory = try #require(MorningReadiness(load: RecoveryModel(workouts: []),
                                                      checkin: DailyCheckin(energy: .ok, legs: .ok)))
        #expect(noHistory.pillars.map(\.kind) == [.checkin])
    }

    // MARK: HRV / resting-HR paths

    @Test func hrvPrefersBandedZOverRatioFallback() throws {
        // Banded 60±5 + HRV 66 → z = 1.2 → 50 + 24 = 74. The ratio path would say 75
        // (66/60 = 1.10 ≥ 1.05) — the finer z wins whenever the baseline is banded.
        let banded = try #require(MorningReadiness(signals: RecoverySignals(hrvMs: 66, hrvBaselineMs: 60),
                                                   hrvBaseline: baseline(60, sd: 5)))
        #expect(banded.score == 74)

        // Six days of history — below the 7-day banding bar — falls back to the coarse ratio.
        let unbanded = try #require(MorningReadiness(signals: RecoverySignals(hrvMs: 66, hrvBaselineMs: 60),
                                                     hrvBaseline: baseline(60, sd: 5, days: 6)))
        #expect(unbanded.score == 75)
    }

    @Test func hrvRatioFallbackMatchesTrendCuts() throws {
        // Single-pillar mornings (HRV only, weight 1) against a plain 30-day average of 60 —
        // the same cuts as `RecoverySignals.hrvTrend`: ≥1.05 → 75 · ≥0.92 → 55 · ≥0.82 → 30 · else 10.
        func score(hrv: Double) throws -> Int {
            try #require(MorningReadiness(signals: RecoverySignals(hrvMs: hrv, hrvBaselineMs: 60))).score
        }
        #expect(try score(hrv: 63) == 75)     // 63/60 = 1.05 — the boundary sits in the top band
        #expect(try score(hrv: 57) == 55)     // 0.95
        #expect(try score(hrv: 51) == 30)     // 0.85
        #expect(try score(hrv: 48) == 10)     // 0.80
    }

    @Test func zPathClampsAtPlusMinusTwoPointFiveSD() throws {
        // 60±5 baseline: a 200 ms artifact clamps at z = +2.5 → 100; a wrecked 20 ms night at
        // z = −2.5 → 0. A single wild sample can never leave the 0–100 rails.
        let high = try #require(MorningReadiness(signals: RecoverySignals(hrvMs: 200),
                                                 hrvBaseline: baseline(60, sd: 5)))
        #expect(high.score == 100 && high.band == .primed)
        let low = try #require(MorningReadiness(signals: RecoverySignals(hrvMs: 20),
                                                hrvBaseline: baseline(60, sd: 5)))
        #expect(low.score == 0 && low.band == .depleted)
    }

    @Test func restingHRInvertsTheZAxis() throws {
        // 50±2 baseline, single pillar — elevated is worse: 55 → z = +2.5 → 50 − 50 = 0;
        // 45 → z = −2.5 → 100; 51 → z = +0.5 → 50 − 10 = 40.
        func score(rhr: Int) throws -> Int {
            try #require(MorningReadiness(signals: RecoverySignals(restingHR: rhr),
                                          restingHRBaseline: baseline(50, sd: 2))).score
        }
        #expect(try score(rhr: 55) == 0)
        #expect(try score(rhr: 45) == 100)
        #expect(try score(rhr: 51) == 40)
    }

    @Test func restingHRDeltaFallbackMatchesTrendCuts() throws {
        // No banded baseline — the coarse Δ vs the plain 30-day average (50), matching
        // `restingHRTrend` plus the genuinely-below-norm tier: ≤−2 → 75 · <1 → 60 · <4 → 40 · else 15.
        func score(rhr: Int) throws -> Int {
            try #require(MorningReadiness(signals: RecoverySignals(restingHR: rhr, restingHRBaseline: 50))).score
        }
        #expect(try score(rhr: 48) == 75)     // Δ = −2, genuinely below your norm
        #expect(try score(rhr: 50) == 60)     // steady
        #expect(try score(rhr: 52) == 40)     // slightly up (the 1..<4 caution)
        #expect(try score(rhr: 56) == 15)     // well elevated
    }

    // MARK: Sleep / check-in pillars

    @Test func sleepPillarScoresShortfallAndCappedDebt() throws {
        // 100 − 25·max(0, need − night) − 2.5·min(debt, 12), need defaulting to 8 h. Single pillar.
        func score(night: Double, debt: Double = 0) throws -> Int {
            try #require(MorningReadiness(signals: RecoverySignals(sleepHours: night),
                                          sleepDebt14H: debt)).score
        }
        #expect(try score(night: 6) == 50)             // 100 − 25·2
        #expect(try score(night: 8) == 100)            // fully slept, no debt
        #expect(try score(night: 9.5) == 100)          // oversleep is not a bonus (clamped)
        #expect(try score(night: 3) == 0)              // 100 − 125 → floor 0
        #expect(try score(night: 8, debt: 20) == 70)   // debt caps at 12 h → 100 − 30
        #expect(try score(night: 7, debt: 4) == 65)    // 100 − 25 − 10
    }

    @Test func checkinPillarMapsEnergyAndLegs() throws {
        // 60 + energy{−25/0/+20} + legs{+20/0/−20/−35}, clamped 0–100. Single pillar → verbatim.
        func score(_ energy: DailyCheckin.Energy, _ legs: DailyCheckin.Legs) throws -> Int {
            try #require(MorningReadiness(checkin: DailyCheckin(energy: energy, legs: legs))).score
        }
        #expect(try score(.full, .fresh) == 100)       // 60 + 20 + 20
        #expect(try score(.ok, .ok) == 60)
        #expect(try score(.low, .heavy) == 15)         // 60 − 25 − 20
        #expect(try score(.low, .sore) == 0)           // 60 − 25 − 35
        #expect(try score(.full, .sore) == 45)         // 60 + 20 − 35
    }

    // MARK: The invariant — one noisy night can't crater a Primed athlete

    @Test func onePillarCanNeverMoveTheScoreMoreThanThirty() throws {
        // With all five pillars present the raw weights apply directly and none exceeds .30 —
        // so even a full 0→100 swing of one pillar moves the blend by at most 30 points.
        let base = try #require(morning(load: strongLoad))          // the golden 85, primed
        #expect(base.pillars.allSatisfy { $0.weight <= 0.30 + 0.000_000_1 })

        // Crater each pillar to its worst case, everything else held:
        //   load 100 → 60 (grind): −12 · HRV 70 → 0 (z-clamped): −17.5 · RHR 70 → 0: −10.5
        //   sleep 85 → 0 (3 h night): −17 · check-in 100 → 0 (drained + sore): −10.
        let worstCases: [MorningReadiness?] = [
            morning(load: grindLoad),
            morning(load: strongLoad, hrv: 20),
            morning(load: strongLoad, rhr: 60),
            morning(load: strongLoad, sleep: 3),
            morning(load: strongLoad, checkin: DailyCheckin(energy: .low, legs: .sore)),
        ]
        for c in worstCases {
            let r = try #require(c)
            #expect(abs(r.score - base.score) <= 30)
            #expect(r.band != .depleted && r.band != .strained)     // primed dips, never craters
        }
        // The cleanly exact one: sleep 85 → 0 is a .20·85 = 17-point dip → 68, still ready.
        let shortNight = try #require(morning(load: strongLoad, sleep: 3))
        #expect(shortNight.score == 68)
        #expect(shortNight.band == .ready)
    }

    // MARK: Modifiers

    @Test func modifierTiersAndBoundaries() throws {
        // Off the golden 85: respiratory z ≥ 2 → −10, z ∈ [1,2) → −5; wrist temp Δ ≥ 1.0 °C → −10,
        // Δ ∈ [0.5,1.0) → −5; below threshold → silent.
        func variant(z: Double? = nil, temp: Double? = nil) throws -> MorningReadiness {
            try #require(morning(load: strongLoad, respiratoryZ: z, wristTempDeltaC: temp))
        }
        #expect(try variant(z: 2.0).score == 75)               // boundary → −10
        #expect(try variant(z: 1.0).score == 80)               // boundary → −5
        #expect(try variant(z: 0.99).score == 85)              // sub-threshold → silent
        #expect(try variant(z: 0.99).modifiers.isEmpty)
        #expect(try variant(temp: 1.0).score == 75)
        #expect(try variant(temp: 0.5).score == 80)
        #expect(try variant(temp: 0.49).score == 85)
        #expect(try variant(z: 1.5, temp: 0.7).score == 75)    // −5 − 5 = −10, no floor needed
    }

    @Test func combinedModifiersFloorAtMinusFifteen() throws {
        // Both firing hard would read −20 — the floor holds it at −15: corroborating body signals
        // cap, they don't stack without bound. 85 − 15 = 70, ready (not strained).
        let r = try #require(morning(load: strongLoad, respiratoryZ: 2.5, wristTempDeltaC: 1.2))
        #expect(r.modifiers.count == 2)
        #expect(r.modifiers.allSatisfy { $0.points == -10 })
        #expect(r.modifiers.reduce(0) { $0 + $1.points } == -20)   // the raw sum…
        #expect(r.modifierPoints == -15)                           // …floored where it's applied
        #expect(r.score == 70)
        #expect(r.band == .ready)

        // And modifiers never drag the final score below zero.
        let floor = try #require(MorningReadiness(signals: RecoverySignals(sleepHours: 3, respiratoryZ: 2.5)))
        #expect(floor.score == 0)
    }

    // MARK: Band parity

    @Test func bandBoundariesMatchRecoveryModelsCuts() throws {
        // Single HRV pillar against 60±5: score = 50 + 20·(v − 60)/5 = 50 + 4·(v − 60), so
        // quarter-ms steps land on exact integers — walk both sides of every cut (25/45/65/80).
        func single(at hrv: Double) throws -> MorningReadiness {
            try #require(MorningReadiness(signals: RecoverySignals(hrvMs: hrv),
                                          hrvBaseline: baseline(60, sd: 5)))
        }
        let cases: [(hrv: Double, score: Int, band: RecoveryModel.Readiness)] = [
            (53.5,  24, .depleted), (53.75, 25, .strained),
            (58.5,  44, .strained), (58.75, 45, .moderate),
            (63.5,  64, .moderate), (63.75, 65, .ready),
            (67.25, 79, .ready),    (67.5,  80, .primed),
        ]
        for c in cases {
            let r = try single(at: c.hrv)
            #expect(r.score == c.score)
            #expect(r.band == c.band)
            #expect(r.band == RecoveryModel.band(r.score))   // one banding function app-wide
        }
    }

    // MARK: Confidence

    @Test func confidenceFollowsPillarCount() throws {
        // 5 → high · 4 → medium · 3 → low · ≤2 → minimal.
        #expect(try #require(morning(load: strongLoad)).confidence == .high)
        #expect(try #require(morning(load: strongLoad, checkin: nil)).confidence == .medium)
        #expect(try #require(morning(load: strongLoad, rhr: nil, checkin: nil)).confidence == .low)
        #expect(try #require(morning(load: strongLoad, hrv: nil, rhr: nil, sleep: nil)).confidence == .minimal)
        #expect(try #require(MorningReadiness(signals: RecoverySignals(sleepHours: 8))).confidence == .minimal)
    }

    /// A thin-signal score must SAY it's thin on every surface that shows it, not just the hub's
    /// hero footnote. Today and Trends speak `displayDriverWithConfidence`; before this, a
    /// watch-less athlete's check-in-and-load number read exactly like a full-signal morning.
    @Test func thinSignalCarriesItsQualifierIntoTheDriverLine() throws {
        let full = try #require(morning(load: strongLoad))
        #expect(full.confidenceNote == nil, "A full-signal morning should not apologise for itself.")
        #expect(full.displayDriverWithConfidence == full.displayDriverLine)

        let partial = try #require(morning(load: strongLoad, rhr: nil, checkin: nil))
        #expect(partial.confidenceNote == "partial signal")
        #expect(partial.displayDriverWithConfidence == "\(partial.displayDriverLine) · partial signal")

        // The watch-less case this exists for: no HRV, no resting HR, no sleep.
        let phoneOnly = try #require(morning(load: strongLoad, hrv: nil, rhr: nil, sleep: nil))
        #expect(phoneOnly.confidenceNote == "light signal")
        #expect(phoneOnly.displayDriverWithConfidence.hasSuffix(" · light signal"))
        // Still a real number with real guidance — the qualifier never replaces the score.
        #expect(phoneOnly.score > 0)
    }
}
