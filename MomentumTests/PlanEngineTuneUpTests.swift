import Testing
import Foundation
@testable import Momentum

/// Tune-up races bend the week they land in and never the block (2026-09-03). A B race is raced:
/// two easy days in, the race in place of the week's quality (and of the long run when it is a
/// half or longer), easy days out. A C race is trained through. The phases toward the goal race
/// are identical with and without them, the synthetic time trial stands down, and every invariant
/// the sweep holds still holds.
struct PlanEngineTuneUpTests {

    private let start = Date(timeIntervalSinceReferenceDate: 0)   // a Monday
    private let cal = Calendar.current

    private func race(weeksOut: Int) -> Date { cal.date(byAdding: .weekOfYear, value: weeksOut, to: start)! }
    private func day(week: Int, offset: Int) -> Date { cal.date(byAdding: .day, value: week * 7 + offset, to: start)! }

    private func marathonInputs(days: Int = 5) -> PlanInputs {
        var inp = PlanInputs(disciplines: [.running], goal: .raceDistance, daysPerWeek: days,
                             equipment: .fullGym, sessionMinutes: 60, raceDate: race(weeksOut: 16),
                             runningExperience: .experienced, liftingExperience: .some)
        inp.raceDistanceM = 42_195
        inp.currentWeeklyVolumeM = 48_000
        inp.longestRunM = 18_000
        inp.preferredDayOffsets = [1, 2, 3, 5, 6]   // Tue Wed Thu Sat Sun
        return inp
    }

    private func generate(_ inputs: PlanInputs) -> GeneratedPlan {
        var seed = CalibrationSeed.none
        seed.estimatedP5kSPerKm = 250
        return PlanEngine.generate(profile: inputs, catalog: [], calibration: seed, startDate: start, calendar: cal)
    }

    private func sessions(_ plan: GeneratedPlan, week: Int) -> [GeneratedSession] { plan.weeks[week].sessions }

    /// A build week that is not a cutback in the plain plan, at or after `from` — so a tune-up
    /// placed there tests the bend itself, not the cadence shift a cutback collision causes.
    private func loadingBuildWeek(in plan: GeneratedPlan, from: Int) -> Int {
        (from..<plan.weeks.count).first { !plan.weeks[$0].isDeload && plan.weeks[$0].phase == .build }!
    }
    private func raceSession(_ plan: GeneratedPlan, week: Int) -> GeneratedSession? {
        sessions(plan, week: week).first { $0.runType == .race }
    }

    // MARK: Placement

    @Test func aTuneUpLandsOnItsDayAtItsDistanceAndPredictedPace() {
        var inp = marathonInputs()
        let tenK = PlanRaceEvent(id: UUID(), date: day(week: 8, offset: 6), distanceM: 10_000, priority: .b)
        inp.tuneUpRaces = [tenK]
        let plan = generate(inp)
        let race = try! #require(raceSession(plan, week: 8))
        #expect(race.dayOffset == 6)
        #expect(race.targetDistanceM == 10_000)
        #expect(race.intervals == "Tune-up · Race it")
        #expect(race.isHardRun)
        #expect(race.targetPaceSPerKm == RunRounding.snapPace(
            sPerKm: DanielsPaces.racePaceSPerKm(distanceM: 10_000, p5kSPerKm: 250), unit: .metric, type: .race))
        // A goal time sets the pace instead.
        inp.tuneUpRaces = [PlanRaceEvent(id: UUID(), date: day(week: 8, offset: 6), distanceM: 10_000,
                                         priority: .b, goalTimeS: 45 * 60)]
        let timed = try! #require(raceSession(generate(inp), week: 8))
        #expect(timed.targetPaceSPerKm == RunRounding.snapPace(sPerKm: 270, unit: .metric, type: .race))
    }

    @Test func tuneUpsOutsideTheWindowOrAfterTheGoalAreIgnored() {
        var inp = marathonInputs()
        inp.tuneUpRaces = [
            PlanRaceEvent(id: UUID(), date: day(week: 17, offset: 2), distanceM: 10_000, priority: .b),   // after the goal
            PlanRaceEvent(id: UUID(), date: cal.date(byAdding: .day, value: -3, to: start)!, distanceM: 5_000, priority: .c),
        ]
        let plan = generate(inp)
        let races = plan.weeks.flatMap(\.sessions).filter { $0.runType == .race }
        #expect(races.count == 1)   // the goal race only
        #expect(races.first?.intervals == nil)
    }

    // MARK: The B week

    @Test func aRacedTuneUpBendsItsWeekAndOnlyItsWeek() {
        var inp = marathonInputs()
        let control = generate(inp)
        let w = loadingBuildWeek(in: control, from: 6)
        let tenK = PlanRaceEvent(id: UUID(), date: day(week: w, offset: 6), distanceM: 10_000, priority: .b)
        inp.tuneUpRaces = [tenK]
        let plan = generate(inp)
        let week = sessions(plan, week: w)
        // The race is the week's one hard run.
        let hard = week.filter { $0.discipline == .running && $0.isHardRun }
        #expect(hard.count == 1 && hard.first?.runType == .race)
        // Two easy days in: whatever runs sit on the two days before are easy and shortened.
        for s in week where s.discipline == .running && (s.dayOffset == 4 || s.dayOffset == 5) {
            #expect(s.runType == .easy && !s.isHardRun && s.intervals == nil)
        }
        // The race takes its day outright: a Sunday tune-up stands where the long run stood, and
        // no race-pace finish survives anywhere in the week.
        #expect(!week.contains { $0.dayOffset == 6 && $0.runType != .race })
        #expect(!week.contains { ($0.intervals ?? "").lowercased().contains("race pace") })
        // Recovery spills into the next week: a Sunday race earns two easy days for a 10K, so the
        // Tuesday run of the following week is a recovery run at 60 % of itself.
        let tuesday = try! #require(sessions(plan, week: w + 1).first { $0.dayOffset == 1 && $0.discipline == .running })
        let tuesdayControl = try! #require(sessions(control, week: w + 1).first { $0.dayOffset == 1 && $0.discipline == .running })
        #expect(tuesday.runType == .recovery && !tuesday.isHardRun)
        #expect((tuesday.targetDistanceM ?? 0) <= (tuesdayControl.targetDistanceM ?? 0) * 0.6 + 1_000)
        // Everything before the tune-up week is exactly what it would have been — except the
        // week that carried the synthetic time trial, which a real race replaces.
        for earlier in 0..<w where !control.weeks[earlier].sessions.contains(where: { $0.intervals?.contains("Time trial") == true }) {
            #expect(plan.weeks[earlier].sessions == control.weeks[earlier].sessions, "week \(earlier) should not change")
        }
        #expect(!plan.weeks[w].isDeload)
    }

    @Test func aRacedHalfReplacesTheLongRunAndHoldsTheNextOne() {
        var inp = marathonInputs()
        let control = generate(inp)
        let w = loadingBuildWeek(in: control, from: 8)
        let half = PlanRaceEvent(id: UUID(), date: day(week: w, offset: 6), distanceM: RaceDistance.half.meters, priority: .b)
        inp.tuneUpRaces = [half]
        let plan = generate(inp)
        let week = sessions(plan, week: w)
        #expect(!week.contains { $0.runType == .long || $0.runType == .progression })
        #expect(raceSession(plan, week: w)?.targetDistanceM == RaceDistance.half.meters)
        // Two easy days out (a half is under the 25 km line): the runs on the first two days of
        // the next week are recovery runs at 60 %.
        let after = sessions(plan, week: w + 1)
        let afterControl = sessions(control, week: w + 1)
        for s in after where s.discipline == .running && s.dayOffset <= 1 {
            #expect(s.runType == .recovery && !s.isHardRun, "day \(s.dayOffset) after a half should be recovery")
            if let c = afterControl.first(where: { $0.dayOffset == s.dayOffset }), let cd = c.targetDistanceM {
                #expect((s.targetDistanceM ?? 0) <= cd * 0.6 + 1_000)
            }
        }
        // The next long run is held to three quarters.
        let nextLong = after.first { $0.runType == .long || $0.runType == .progression }?.targetDistanceM ?? 0
        let controlLong = afterControl.first { $0.runType == .long || $0.runType == .progression }?.targetDistanceM ?? 0
        #expect(nextLong <= controlLong * 0.75 + 1_000 && nextLong > 0)
    }

    // MARK: The C week

    @Test func aTrainedThroughTuneUpOnlyStandsInForTheQualitySession() {
        var inp = marathonInputs()
        let control = generate(inp)
        let w = loadingBuildWeek(in: control, from: 4)
        let fiveK = PlanRaceEvent(id: UUID(), date: day(week: w, offset: 3), distanceM: 5_000, priority: .c)
        inp.tuneUpRaces = [fiveK]
        let plan = generate(inp)
        let week = sessions(plan, week: w)
        let race = try! #require(raceSession(plan, week: w))
        #expect(race.intervals == "Tune-up · Train through")
        let hard = week.filter { $0.discipline == .running && $0.isHardRun && $0.runType != .long && $0.runType != .progression }
        #expect(hard.count == 1)
        // The day after is easy, the day before is untouched, the long run keeps its size.
        if let next = week.first(where: { $0.dayOffset == 4 && $0.discipline == .running }) {
            #expect(next.runType == .easy && !next.isHardRun)
        }
        let before = week.first { $0.dayOffset == 2 }
        let beforeControl = control.weeks[w].sessions.first { $0.dayOffset == 2 }
        #expect(before?.targetDistanceM == beforeControl?.targetDistanceM)
        let long = week.first { $0.runType == .long || $0.runType == .progression }?.targetDistanceM
        let controlLong = control.weeks[w].sessions.first { $0.runType == .long || $0.runType == .progression }?.targetDistanceM
        #expect(long == controlLong)
    }

    // MARK: The block

    @Test func thePhasesAndTheTaperAreUntouchedByTuneUps() {
        var inp = marathonInputs()
        let control = generate(inp)
        let w1 = loadingBuildWeek(in: control, from: 4)
        let w2 = loadingBuildWeek(in: control, from: w1 + 2)
        let w3 = loadingBuildWeek(in: control, from: w2 + 2)
        inp.tuneUpRaces = [
            PlanRaceEvent(id: UUID(), date: day(week: w1, offset: 3), distanceM: 5_000, priority: .c),
            PlanRaceEvent(id: UUID(), date: day(week: w2, offset: 6), distanceM: 10_000, priority: .b),
            PlanRaceEvent(id: UUID(), date: day(week: w3, offset: 6), distanceM: RaceDistance.half.meters, priority: .b),
        ]
        let plan = generate(inp)
        #expect(plan.weeks.map(\.phase) == control.weeks.map(\.phase))
        #expect(plan.weeks.map(\.isTaper) == control.weeks.map(\.isTaper))
        #expect(plan.weeks.count == control.weeks.count)
        for w in [w1, w2, w3] { #expect(!plan.weeks[w].isDeload, "week \(w) should not be a cutback") }
        // The goal race is still the last session of the plan.
        let last = plan.weeks.last!.sessions.last!
        #expect(last.runType == .race && last.targetDistanceM == 42_195 && last.intervals == nil)
    }

    @Test func aTuneUpOnACutbackWeekMovesTheCutbackLater() {
        // A race is not absorption: the week loads, and the cadence takes its cutback within the
        // next two weeks instead.
        var inp = marathonInputs()
        let control = generate(inp)
        guard let cut = (3..<12).first(where: { control.weeks[$0].isDeload }) else { return }
        inp.tuneUpRaces = [PlanRaceEvent(id: UUID(), date: day(week: cut, offset: 6), distanceM: 10_000, priority: .b)]
        let plan = generate(inp)
        #expect(!plan.weeks[cut].isDeload)
        #expect(plan.weeks[cut].sessions.contains { $0.runType == .race })
        #expect((cut + 1...cut + 2).contains { plan.weeks.indices.contains($0) && plan.weeks[$0].isDeload })
    }

    @Test func theSyntheticTimeTrialStandsDownWhenARealRaceIsOnTheSeason() {
        let plain = generate(marathonInputs())
        #expect(plain.weeks.flatMap(\.sessions).contains { $0.intervals?.contains("Time trial") == true })
        var inp = marathonInputs()
        inp.tuneUpRaces = [PlanRaceEvent(id: UUID(), date: day(week: 9, offset: 6), distanceM: 10_000, priority: .b)]
        let withTuneUp = generate(inp)
        #expect(!withTuneUp.weeks.flatMap(\.sessions).contains { $0.intervals?.contains("Time trial") == true })
    }

    @Test func recoveryDaysScaleWithTheDistance() {
        #expect(PlanEngine.tuneUpRecoveryDays(forRaceM: 5_000) == 1)
        #expect(PlanEngine.tuneUpRecoveryDays(forRaceM: 10_000) == 2)
        #expect(PlanEngine.tuneUpRecoveryDays(forRaceM: 21_097) == 2)
        #expect(PlanEngine.tuneUpRecoveryDays(forRaceM: 25_000) == 4)
        #expect(PlanEngine.tuneUpRecoveryDays(forRaceM: 42_195) == 4)
    }

    @Test func generationWithTuneUpsIsDeterministic() {
        var inp = marathonInputs()
        inp.tuneUpRaces = [PlanRaceEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                         date: day(week: 9, offset: 6), distanceM: 10_000, priority: .b)]
        #expect(generate(inp) == generate(inp))
    }
}
