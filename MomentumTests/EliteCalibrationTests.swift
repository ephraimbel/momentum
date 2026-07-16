import Testing
import Foundation
@testable import Momentum

/// Elite-athlete calibration — the "Olympic runner onboards" path. The plan engine's VDOT zones are
/// curvilinear and handle elite fitness natively; these tests pin the INPUT layer (benchmark entry
/// ranges) and the seed→zones pipeline so a sub-elite's plan starts at their true paces instead of
/// silently capping at recreational fitness (the old floors were 5:00 mile / 15:00 5K / 30:00 10K —
/// a 13:00 5K runner couldn't even enter their time).
struct EliteCalibrationTests {

    // MARK: Benchmark entry ranges admit real elite times

    @Test func benchmarkRangesCoverWorldClassTimes() {
        // Just-off-world-record times must be enterable (mile WR ≈ 3:43, 5K ≈ 12:35, 10K ≈ 26:11).
        #expect(RunBenchmark.mile.range.contains(224))     // 3:44 mile
        #expect(RunBenchmark.fiveK.range.contains(756))    // 12:36 5K
        #expect(RunBenchmark.tenK.range.contains(1_572))   // 26:12 10K
        // Sub-elite/collegiate times too (4:10 mile, 13:30 5K, 28:30 10K).
        #expect(RunBenchmark.mile.range.contains(250))
        #expect(RunBenchmark.fiveK.range.contains(810))
        #expect(RunBenchmark.tenK.range.contains(1_710))
        // The slow end stays generous (walk-jog 5K in 60:00 remains enterable).
        #expect(RunBenchmark.fiveK.range.contains(3_600))
    }

    @Test func benchmarkFloorsStayOnStepGrid() {
        // Steppers move by `step` from `defaultSeconds`; a floor off the grid would be unreachable.
        for b in RunBenchmark.allCases {
            let span = b.defaultSeconds - b.range.lowerBound
            #expect(span.truncatingRemainder(dividingBy: b.step) == 0,
                    "\(b.label) floor unreachable by stepping")
        }
    }

    // MARK: Elite seed → correct plan paces end to end

    @Test func eliteFiveKSeedsProportionalZones() {
        // A 13:00 5K athlete (p5k = 156 s/km ≈ 2:36/km).
        let p5k = PlanEngine.riegelP5k(distanceM: 5_000, timeS: 780)
        #expect(abs(p5k - 156) < 0.5)

        let easy = DanielsPaces.trainingPace(.easy, p5kSPerKm: p5k)
        let tempo = DanielsPaces.trainingPace(.tempo, p5kSPerKm: p5k)
        let intervals = DanielsPaces.trainingPace(.intervals, p5kSPerKm: p5k)
        // Ordering invariant: intervals < tempo < easy (s/km — faster is smaller).
        #expect(intervals < tempo && tempo < easy)
        // Elite easy pace lands in the real-world elite range (~3:20–4:20/km), nowhere near
        // the recreational defaults — the proportionality the VDOT curves exist for.
        #expect((200...260).contains(easy), "elite easy pace was \(easy) s/km")
        // Interval (vVO₂max) pace is faster than threshold but not absurd (>2:00/km floor).
        #expect(intervals >= 120 && intervals < p5k)
    }

    @Test func eliteTenKSeedSurvivesTheClampFloor() {
        // 26:30 10K Riegels to p5k ≈ 152 s/km — just above DanielsPaces' 150 sanity floor. The
        // whole zone set must stay finite, ordered, and elite-fast rather than degrade.
        let p5k = PlanEngine.riegelP5k(distanceM: 10_000, timeS: 1_590)
        #expect(p5k > 150 && p5k < 160)
        let easy = DanielsPaces.trainingPace(.easy, p5kSPerKm: p5k)
        let intervals = DanielsPaces.trainingPace(.intervals, p5kSPerKm: p5k)
        #expect(easy.isFinite && intervals.isFinite && intervals < easy)
        #expect(easy < 270)   // still an elite prescription, not a recreational one
    }

    @Test func eliteMarathonPaceIsRealistic() {
        // A 13:00 5K athlete's predicted marathon race pace ≈ world-class (2:05–2:20 → ~178–198 s/km).
        let m = DanielsPaces.marathonPaceSPerKm(p5kSPerKm: 156)
        #expect((170...205).contains(m), "elite marathon pace was \(m) s/km")
    }

    // MARK: Health-import baseline admits elite training paces

    @Test func baselineEstimatorAcceptsEliteTrainingRuns() {
        // An elite's tempo session: 10 km at 2:55/km (175 s/km) — must pass the sanity filter and
        // produce an elite seed, not be dropped as "GPS junk".
        let now = Date()
        let runs = (0..<4).map { i in
            BaselineEstimator.RunSample(date: now.addingTimeInterval(Double(-i * 3) * 86_400),
                                        distanceM: 10_000, durationS: 1_750)
        }
        let baseline = BaselineEstimator.estimate(from: runs, now: now)
        #expect(baseline != nil)
        // 10 km @ 175 s/km Riegels to a ~168 s/km 5K — an elite seed.
        #expect(baseline.map { $0.p5kSPerKm < 180 } == true)
    }
}
