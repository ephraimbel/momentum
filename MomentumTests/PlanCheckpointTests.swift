import Testing
import Foundation
@testable import Momentum

/// The open-block checkpoint (2026-09-07): an athlete with no race gets a measured answer to "am I
/// getting better?" at the end of every rolling block, sized to who they are, and the block report
/// reads the result back in a coach's words.
struct PlanCheckpointTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func inputs(experience: ExperienceLevel, weeklyM: Double?, goal: Goal = .endurance,
                        days: Int = 4, injuries: [InjuryArea] = []) -> PlanInputs {
        var p = PlanInputs(disciplines: [.running], goal: goal, daysPerWeek: days, equipment: .bodyweight,
                           sessionMinutes: 60, raceDate: nil, runningExperience: experience,
                           liftingExperience: .new)
        p.currentWeeklyVolumeM = weeklyM
        p.longestRunM = weeklyM.map { $0 * 0.3 }
        p.distanceUnit = .metric
        p.injuryHistory = injuries
        return p
    }

    private func plan(_ p: PlanInputs) -> GeneratedPlan {
        PlanEngine.generate(profile: p, catalog: [], startDate: start)
    }

    private func checkpoints(_ plan: GeneratedPlan) -> [(week: Int, session: GeneratedSession)] {
        plan.weeks.enumerated().flatMap { w, week in
            week.sessions.filter { $0.intervals?.contains("Time trial") == true }.map { (w, $0) }
        }
    }

    // MARK: - Who tests, over what

    @Test func openBlockEndsWithACheckpointSizedToTheAthlete() {
        let cases: [(ExperienceLevel, Double, Double, String)] = [
            (.new, 12_000, 1609.344, "1 mile"),
            (.some, 26_000, 3_000, "3K"),
            (.experienced, 48_000, 5_000, "5K"),
        ]
        for (experience, weekly, meters, word) in cases {
            let p = plan(inputs(experience: experience, weeklyM: weekly))
            #expect(p.weeks.count == PlanEngine.openBlockWeeks)
            let found = checkpoints(p)
            #expect(found.count == 1, "\(experience): one checkpoint per block, got \(found.count)")
            guard let (week, tt) = found.first else { continue }
            #expect(week == PlanEngine.openBlockWeeks - 1, "the checkpoint closes the block")
            #expect(tt.targetDistanceM == meters)
            #expect(tt.intervals?.contains(word) == true, "\(tt.intervals ?? "")")
            #expect(tt.isHardRun && tt.runType == .tempo)
            #expect(!p.weeks[week].isDeload, "a test never lands on a cutback")
            #expect(tt.rationale?.contains("A checkpoint, not a race") == true)
        }
    }

    @Test func whoDoesNotTest() {
        // The habit builder carries no quality at all, so no test either.
        #expect(checkpoints(plan(inputs(experience: .some, weeklyM: 26_000, goal: .stayConsistent))).isEmpty)
        // Impact- or speed-sensitive history: a maximal effort is the classic re-injury mechanism.
        #expect(checkpoints(plan(inputs(experience: .some, weeklyM: 26_000, injuries: [.knee]))).isEmpty)
        #expect(checkpoints(plan(inputs(experience: .some, weeklyM: 26_000, injuries: [.hamstring]))).isEmpty)
        // Cross-training only: nothing to time-trial.
        var cycling = inputs(experience: .some, weeklyM: 26_000)
        cycling.disciplines = [.cycling]
        #expect(checkpoints(plan(cycling)).isEmpty)
    }

    @Test func racePlansKeepTheirOwnCheckpointRule() {
        // A 12-week 10K build carries the single 5K checkpoint on the first build week, as before.
        var race = inputs(experience: .some, weeklyM: 32_000)
        race.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 12, to: start)
        race.raceDistanceM = 10_000
        let found = checkpoints(plan(race))
        #expect(found.count == 1)
        #expect(found.first?.session.targetDistanceM == 5_000)
        #expect(found.first?.session.intervals == "Time trial: 5K at race effort")
    }

    @Test func hybridAthletesTestOverTheirRunningWeek() {
        // A three-day hybrid on 20 km a week runs about 13 km of it: a mile, not the 3K their
        // declared total would suggest. Sized to the running week, the test stays a small share of it.
        var hybrid = inputs(experience: .experienced, weeklyM: 20_000, days: 3)
        hybrid.disciplines = [.running, .strength]
        let p = plan(hybrid)
        let found = checkpoints(p)
        #expect(found.count == 1)
        guard let (week, tt) = found.first else { return }
        #expect(tt.targetDistanceM == 1609.344, "\(tt.targetDistanceM ?? 0)")
        let runningWeek = p.weeks[week].sessions.filter { $0.discipline == .running }
            .reduce(0.0) { $0 + ($1.targetDistanceM ?? 0) }
        #expect(runningWeek > 0 && 1_609 / runningWeek < 0.30, "the test is a small share of the running week")
    }

    @Test func timeTrialLabelsReadBackTheirDistance() {
        #expect(PlanEngine.timeTrialDistanceM(intervals: "Time trial: 1 mile at a strong, steady effort") == 1609.344)
        #expect(PlanEngine.timeTrialDistanceM(intervals: "Time trial: 3K at race effort") == 3_000)
        #expect(PlanEngine.timeTrialDistanceM(intervals: "Time trial: 5K at race effort") == 5_000)
        #expect(PlanEngine.timeTrialDistanceM(intervals: "6x400m @ I") == nil)
        #expect(PlanEngine.timeTrialDistanceM(intervals: nil) == nil)
    }

    @Test func checkpointPaceFitsTheDistance() {
        let three = plan(inputs(experience: .some, weeklyM: 26_000))
        let mile = plan(inputs(experience: .new, weeklyM: 12_000))
        guard let tt3 = checkpoints(three).first?.session, let ttMile = checkpoints(mile).first?.session else {
            Issue.record("both plans should carry a checkpoint"); return
        }
        // 3K race pace is quicker than the same athlete's 5K race pace.
        let fiveKPace3 = RunRounding.snapPace(sPerKm: PlanEngine.pace(.race, p5k: three.p5kSPerKm), unit: .metric, type: .tempo)
        #expect((tt3.targetPaceSPerKm ?? 0) < fiveKPace3, "3K should be quicker than 5K pace")
        #expect((tt3.targetPaceSPerKm ?? 0) > fiveKPace3 * 0.9, "but not absurdly so")
        // The mile is run strong and steady at 5K pace: a new runner's form is the thing to protect.
        let fiveKPaceMile = RunRounding.snapPace(sPerKm: PlanEngine.pace(.race, p5k: mile.p5kSPerKm), unit: .metric, type: .tempo)
        #expect(ttMile.targetPaceSPerKm == fiveKPaceMile)
        #expect(ttMile.rationale?.contains("strong and steady") == true)
    }

    // MARK: - The test week

    @Test func theTestWeekIsLighterAndFarFromTheLongRun() {
        let p = plan(inputs(experience: .some, weeklyM: 26_000))
        let last = PlanEngine.openBlockWeeks - 1
        let biggestBefore = p.weeks[..<last].filter { !$0.isDeload }.map(\.runVolumeM).max() ?? 0
        let testWeek = p.weeks[last].runVolumeM
        #expect(testWeek < biggestBefore, "the test week eases: \(testWeek) vs \(biggestBefore)")
        #expect(testWeek >= biggestBefore * 0.8, "but only a little")
        guard let tt = checkpoints(p).first?.session,
              let long = p.weeks[last].sessions.first(where: { $0.runType == .long }) else {
            Issue.record("the test week should carry both the checkpoint and the long run"); return
        }
        let gap = abs(tt.dayOffset - long.dayOffset)
        #expect(min(gap, 7 - gap) >= 2, "the test never sits next to the long run")
    }

    @MainActor @Test func notesAndTheWeekAheadKnowTheCheckpointIsComing() {
        let week = CoachNotes.Week(index: 5, total: 6, phase: .build, isDeload: false, isTaper: false,
                                   runDays: 4, runVolumeM: 26_000, longRunDay: 6, hardRunDay: 3,
                                   previousLongRunM: 10_000, weeksToRace: nil, raceDistanceM: nil,
                                   liftDays: 0, checkpointDay: 3)
        let before = CoachNotes.session(GeneratedSession(dayOffset: 2, discipline: .running, runType: .easy, targetDistanceM: 6_000), week: week)
        let after = CoachNotes.session(GeneratedSession(dayOffset: 4, discipline: .running, runType: .easy, targetDistanceM: 6_000), week: week)
        #expect(before.contains("The checkpoint is tomorrow"), "\(before)")
        #expect(after.contains("yesterday's checkpoint"), "\(after)")
        let ahead = CoachNotes.weekAhead(index: 5, total: 6, phase: .build, isDeload: false, isTaper: false,
                                         runs: 4, lifts: 0, hasLong: true, hasHard: true,
                                         weeksToRace: nil, raceName: nil, checkpointDay: "Thursday")
        #expect(ahead.contains("checkpoint on Thursday"), "\(ahead)")
        #expect(!ahead.contains("The easy days matter"), "one closing line, not two")
        for t in [before, after, ahead] {
            CoachVoiceTests.assertCoachVoice(t, "checkpoint week")
            #expect(!t.contains("-"), "\(t)")
        }
    }

    @MainActor @Test func theCheckpointReadSpeaksTheResult() {
        let three = WorkoutReadTemplates.checkpointClause(.init(distanceM: 3_000, timeS: 870), unit: .metric)
        #expect(three.hasPrefix("Checkpoint done:") && three.contains("14:30")
                && three.contains("5K estimate of 24:55") && three.contains("paces move"), "\(three)")
        let mile = WorkoutReadTemplates.checkpointClause(.init(distanceM: 1_609, timeS: 522), unit: .imperial)
        #expect(mile.contains("8:42") && mile.contains("Beat it") && !mile.contains("5K estimate"), "\(mile)")
        for t in [three, mile] { CoachVoiceTests.assertCoachVoice(t, "checkpoint read") }
    }

    // MARK: - The block report

    @MainActor @Test func blockReportReadsLikeACoachAndCarriesTheNumbers() {
        let s = BlockReport.Summary(blockNumber: 2, weeklyVolumeM: 26_000, previousWeeklyVolumeM: 22_000,
                                    longestRunM: 12_000, previousLongestRunM: 10_000,
                                    sessionsPlanned: 18, sessionsDone: 16,
                                    checkpointDistanceM: 3_000, checkpointTimeS: 870,
                                    p5kStartSPerKm: 338, p5kEndSPerKm: 331)
        let t = BlockReport.text(s, unit: .metric)
        #expect(t.headline == "Block 2 in review.")
        #expect(t.lines.count == 5)
        #expect(t.lines[0].hasPrefix("Checkpoint:") && t.lines[0].contains("in 14:30.")
                && t.lines[0].contains("5K estimate of 24:55."), "\(t.lines[0])")
        #expect(t.lines[1] == "Your 5K estimate moved from 28:10 to 27:35 over the block.")
        #expect(t.lines[2].hasPrefix("You ran about") && t.lines[2].contains("a week, up from"))
        #expect(t.lines[3].hasPrefix("Longest run") && t.lines[3].contains("up from"))
        #expect(t.lines[4] == "16 of 18 sessions done.")
        for line in [t.headline] + t.lines + [t.next] {
            CoachVoiceTests.assertCoachVoice(line, "block report")
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "\(line)")
        }
        #expect(BlockReport.message(s, unit: .metric).hasPrefix("Block 2 in review. Checkpoint:"))
    }

    @MainActor @Test func blockReportStaysHonestWithThinData() {
        // A first block with a mile benchmark and nothing else logged: one true line, no padding, and
        // no 5K estimate manufactured from a mile.
        let s = BlockReport.Summary(blockNumber: 1, weeklyVolumeM: nil, previousWeeklyVolumeM: nil,
                                    longestRunM: nil, previousLongestRunM: nil,
                                    sessionsPlanned: 0, sessionsDone: 0,
                                    checkpointDistanceM: 1_609, checkpointTimeS: 522,
                                    p5kStartSPerKm: nil, p5kEndSPerKm: 340)
        let t = BlockReport.text(s, unit: .imperial)
        #expect(t.lines.count == 1)
        #expect(t.lines[0].hasPrefix("Checkpoint:") && t.lines[0].contains("8:42") && !t.lines[0].contains("5K estimate"))
        // A slower estimate is said plainly, without blame.
        let slower = BlockReport.Summary(blockNumber: 3, weeklyVolumeM: 20_000, previousWeeklyVolumeM: 26_000,
                                         longestRunM: 9_000, previousLongestRunM: 12_000,
                                         sessionsPlanned: 12, sessionsDone: 7,
                                         checkpointDistanceM: nil, checkpointTimeS: nil,
                                         p5kStartSPerKm: 330, p5kEndSPerKm: 336)
        let u = BlockReport.text(slower, unit: .metric)
        #expect(u.lines[0].hasPrefix("Your 5K estimate went from 27:30 to 28:00."))
        #expect(u.lines[1].contains("down from") && u.lines[1].contains("not from the plan"))
        #expect(u.lines[2] == "Longest run 9 km." || u.lines[2].hasPrefix("Longest run 9"))
        for line in u.lines { CoachVoiceTests.assertCoachVoice(line, "block report") }
    }

    @Test func clockFormatsMinutesAndHours() {
        #expect(BlockReport.clock(870) == "14:30")
        #expect(BlockReport.clock(522) == "8:42")
        #expect(BlockReport.clock(3_730) == "1:02:10")
    }
}
