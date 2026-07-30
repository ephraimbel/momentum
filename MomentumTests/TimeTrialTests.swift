import Testing
import Foundation
@testable import Momentum

/// The tune-up time trial (pro-practice pass, 2026-07-24): every real long-race build carries a
/// checkpoint race effort. These pin where it appears, what it looks like, and where it must not.
struct TimeTrialTests {

    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func race(weeksOut: Int) -> Date {
        Calendar.current.date(byAdding: .weekOfYear, value: weeksOut, to: start)!
    }

    private func inputs(raceM: Double?, weeksOut: Int?, days: Int = 4,
                        unit: DistanceUnit = .metric) -> PlanInputs {
        var inp = PlanInputs(disciplines: [.running], goal: raceM != nil ? .raceDistance : .endurance,
                             daysPerWeek: days, equipment: .fullGym, sessionMinutes: 45,
                             raceDate: weeksOut.map(race(weeksOut:)),
                             runningExperience: .some, liftingExperience: .some)
        inp.raceDistanceM = raceM
        inp.currentWeeklyVolumeM = 40_000
        inp.longestRunM = 14_000
        inp.distanceUnit = unit
        return inp
    }

    private func timeTrials(_ plan: GeneratedPlan) -> [(week: GeneratedWeek, session: GeneratedSession)] {
        plan.weeks.flatMap { w in w.sessions.filter { $0.intervals?.contains("Time trial") == true }.map { (w, $0) } }
    }

    @Test func marathonBuildCarriesExactlyOneCheckpoint() {
        let plan = PlanEngine.generate(profile: inputs(raceM: 42_195, weeksOut: 14), catalog: [], startDate: start)
        let tts = timeTrials(plan)
        #expect(tts.count == 1, "one checkpoint per block")
        guard let tt = tts.first else { return }
        #expect(tt.week.phase == .build, "the test sits at the end of base — the first build week")
        #expect(!tt.week.isDeload && !tt.week.isTaper)
        #expect(tt.session.runType == .tempo)             // planned quality → feeds recalibration
        #expect(tt.session.isHardRun)
        #expect(tt.session.targetDistanceM == 5_000, "a 5K TT is an exact 5K")
        // The TT is the week's only hard run — the test needs fresh legs to mean anything.
        #expect(tt.week.sessions.filter(\.isHardRun).count == 1)
    }

    @Test func imperialAthletesStillGetAnExactFiveK() {
        let plan = PlanEngine.generate(profile: inputs(raceM: 42_195, weeksOut: 14, unit: .imperial),
                                       catalog: [], startDate: start)
        #expect(timeTrials(plan).first?.session.targetDistanceM == 5_000,
                "canonical snap — never a rounded '3 mi time trial'")
    }

    @Test func shortRunwaysAndShortRacesSkipIt() {
        // <8 weeks: every week is race-specific — no room to spend one on a test.
        #expect(timeTrials(PlanEngine.generate(profile: inputs(raceM: 42_195, weeksOut: 6),
                                               catalog: [], startDate: start)).isEmpty)
        // 5K race: race-pace reps ARE the 5K work; a 5K TT would just be the race early.
        #expect(timeTrials(PlanEngine.generate(profile: inputs(raceM: 5_000, weeksOut: 12),
                                               catalog: [], startDate: start)).isEmpty)
        // No race: rolling blocks recalibrate from ordinary quality days instead.
        #expect(timeTrials(PlanEngine.generate(profile: inputs(raceM: nil, weeksOut: nil),
                                               catalog: [], startDate: start)).isEmpty)
    }

    @Test func twoDayWeeksHaveNoQualitySlotForIt() {
        #expect(timeTrials(PlanEngine.generate(profile: inputs(raceM: 42_195, weeksOut: 14, days: 2),
                                               catalog: [], startDate: start)).isEmpty)
    }

    @Test func longRaceBenchmarksSeedTheEngineHonestly() {
        // The new half/marathon benchmark entries seed from the athlete's OWN race distance, so
        // the goal-distance prescriptions round-trip exactly (a 3:30 marathoner's plan prices
        // marathon pace from a real 3:30, not from a stacked projection off a stale 5K guess).
        // Riegel: 3:30:00 marathon → ~21:53 5K-equivalent (≈263 s/km).
        let p5k = PlanEngine.riegelP5k(distanceM: RunBenchmark.marathon.meters, timeS: 12_600)
        #expect(p5k > 255 && p5k < 270, "marathon benchmark seeds coherent 5K fitness (got \(p5k))")
        // 1:45:00 half → ~22:50 5K-equivalent (≈274 s/km).
        let half = PlanEngine.riegelP5k(distanceM: RunBenchmark.half.meters, timeS: 6_300)
        #expect(half > 265 && half < 285, "half benchmark seeds coherently (got \(half))")
        // Elite floors: the entry ranges admit just-under-WR times.
        #expect(RunBenchmark.half.range.contains(3_460))       // ~57:40
        #expect(RunBenchmark.marathon.range.contains(7_235))   // ~2:00:35
    }
}
