import Testing
import SwiftData
import Foundation
@testable import Momentum

/// The coach's notes on sessions and weeks: specific to the week, varied across it, stable for a
/// given session, and written in the coach's register (no dash of any kind, no shouting, no filler).
@Suite("CoachNotes")
struct CoachNotesTests {

    private func week(index: Int = 3, total: Int = 12, phase: PlanPhase = .build, deload: Bool = false,
                      taper: Bool = false, runDays: Int = 4, volume: Double = 40_000,
                      long: Int? = 6, hard: Int? = 2, prevLong: Double? = 14_000,
                      toRace: Int? = nil, raceM: Double? = nil, lifts: Int = 0) -> CoachNotes.Week {
        .init(index: index, total: total, phase: phase, isDeload: deload, isTaper: taper, runDays: runDays,
              runVolumeM: volume, longRunDay: long, hardRunDay: hard, previousLongRunM: prevLong,
              weeksToRace: toRace, raceDistanceM: raceM, liftDays: lifts)
    }
    private func run(_ type: RunType, day: Int, distance: Double, pace: Double = 360, hard: Bool = false) -> GeneratedSession {
        var s = GeneratedSession(dayOffset: day, discipline: .running)
        s.runType = type; s.targetDistanceM = distance; s.targetPaceSPerKm = pace; s.isHardRun = hard
        return s
    }

    /// Every note, every type, every phase, first and later weeks: the coach's register, and never
    /// a dash of any kind (a hyphen is the machine's tell as much as an em dash).
    @Test @MainActor func everyNoteSpeaksLikeACoachWithNoDashes() {
        var notes: [String] = []
        for phase in [PlanPhase.base, .build, .peak, .taper, .recovery] {
            for index in [0, 1, 5] {
                let w = week(index: index, phase: phase, deload: phase == .recovery, taper: phase == .taper, toRace: phase == .peak ? 3 : nil, raceM: 42_195)
                for type in RunType.allCases {
                    for day in 0..<7 {
                        notes.append(CoachNotes.session(run(type, day: day, distance: type == .long ? 16_000 : 8_000, hard: [.tempo, .intervals, .progression].contains(type)), week: w))
                    }
                }
                var lift = GeneratedSession(dayOffset: 1, discipline: .strength); lift.strengthLabel = "Push"
                notes.append(CoachNotes.session(lift, week: w))
                var ride = GeneratedSession(dayOffset: 4, discipline: .cycling); ride.runType = .easy; ride.targetDistanceM = 20_000
                notes.append(CoachNotes.session(ride, week: w))
                var walk = GeneratedSession(dayOffset: 5, discipline: .walking); walk.runType = .long; walk.targetDistanceM = 8_000
                notes.append(CoachNotes.session(walk, week: w))
                notes.append(CoachNotes.weekAhead(index: index, total: 12, phase: phase, isDeload: phase == .recovery, isTaper: phase == .taper,
                                                  runs: 4, lifts: 2, hasLong: true, hasHard: true, weeksToRace: phase == .peak ? 2 : nil, raceName: nil))
            }
        }
        for t in [1, 2] {
            for target in [nil, 360.0] {
                for actual in [330.0, 360.0, 400.0] {
                    for type in [RunType.easy, .tempo] {
                        if let line = CoachNotes.lookBack(distanceText: "4.1 mi", paceText: "10:12 /mi", actualPaceSPerKm: actual,
                                                          targetPaceSPerKm: target, runType: type, daysAgo: t) { notes.append(line) }
                    }
                }
            }
        }
        #expect(notes.count > 400)
        for n in notes {
            CoachVoiceTests.assertCoachVoice(n, "CoachNotes")
            #expect(!n.contains("-"), "a hyphen is a dash too: \(n)")
            #expect(!n.contains(", the ") && !n.contains(", a "), "conclusion hung off a comma: \(n)")
            #expect(n.hasSuffix("."), "a note ends in a full stop: \(n)")
            #expect(!n.isEmpty)
        }
    }

    /// The note knows the week: the day before the hard day, the day after the long run, the
    /// first week, a cutback, a taper, and the long run against last week's.
    @Test func notesReadTheWeekAroundTheSession() {
        let w = week(index: 3, long: 6, hard: 2)
        #expect(CoachNotes.session(run(.easy, day: 1, distance: 8_000), week: w).contains("tomorrow's hard run"))
        #expect(CoachNotes.session(run(.easy, day: 3, distance: 8_000), week: w).contains("Yesterday was the hard day"))
        #expect(CoachNotes.session(run(.easy, day: 5, distance: 8_000), week: w).contains("long run tomorrow"))
        #expect(CoachNotes.session(run(.easy, day: 0, distance: 8_000), week: week(index: 0, long: 6, hard: 3)).contains("first week"))
        #expect(CoachNotes.session(run(.easy, day: 4, distance: 8_000), week: week(index: 5, phase: .recovery, deload: true, long: nil, hard: nil)).contains("Cutback week"))
        #expect(CoachNotes.session(run(.easy, day: 4, distance: 8_000), week: week(index: 11, phase: .taper, taper: true, long: nil, hard: nil)).contains("taper"))
        // The long run against last week's: longer, the same, shorter on a cutback.
        #expect(CoachNotes.session(run(.long, day: 6, distance: 16_000), week: week(prevLong: 14_000)).contains("longer than last week"))
        #expect(CoachNotes.session(run(.long, day: 6, distance: 16_000), week: week(prevLong: 16_000)).contains("same distance as last week"))
        #expect(CoachNotes.session(run(.long, day: 6, distance: 12_000), week: week(phase: .recovery, deload: true, prevLong: 16_000)).contains("on purpose"))
        // A long run past an hour gets the fuel cue; a short one does not.
        #expect(CoachNotes.session(run(.long, day: 6, distance: 16_000, pace: 360), week: week(index: 4, prevLong: nil)).contains("something to eat"))
        #expect(!CoachNotes.session(run(.long, day: 6, distance: 6_000, pace: 360), week: week(index: 4, prevLong: nil)).contains("something to eat"))
        // Repeats near a race speak about race day; far from one, about the ceiling.
        #expect(CoachNotes.session(run(.intervals, day: 2, distance: 8_000, hard: true), week: week(toRace: 3)).contains("race day"))
        #expect(!CoachNotes.session(run(.intervals, day: 2, distance: 8_000, hard: true), week: week(toRace: 20)).contains("race day"))
    }

    /// The same session always gets the same words (the note is persisted at generation), and the
    /// same run type does not repeat itself word for word across a block.
    @Test func notesAreStableForASessionAndVariedAcrossWeeks() {
        let w = week()
        #expect(CoachNotes.session(run(.easy, day: 4, distance: 8_000), week: w)
                == CoachNotes.session(run(.easy, day: 4, distance: 8_000), week: w))
        var easy = Set<String>(), long = Set<String>()
        for index in 1..<9 {
            let wk = week(index: index, long: 6, hard: 2, prevLong: index % 3 == 0 ? 16_000 : 14_000)
            easy.insert(CoachNotes.session(run(.easy, day: 4, distance: 8_000), week: wk))
            long.insert(CoachNotes.session(run(.long, day: 6, distance: 16_000), week: wk))
        }
        #expect(easy.count >= 3, "easy run notes across a block: \(easy)")
        #expect(long.count >= 2, "long run notes across a block: \(long)")
    }

    /// Notes stay short enough for the deck (two lines at label size) and never carry a unit.
    @Test func notesAreShortAndUnitFree() {
        for type in RunType.allCases {
            let n = CoachNotes.session(run(type, day: 3, distance: 10_000, hard: true), week: week(toRace: 5, raceM: 42_195))
            #expect(n.count <= 190, "\(type): \(n.count) chars: \(n)")
            for unit in [" mi", " km", "/mi", "/km", " miles", " kilometers"] { #expect(!n.contains(unit), "\(type) carries a unit: \(n)") }
        }
    }

    /// The Sunday message names the week, the phase and the shape, in words not counts.
    @Test func weekAheadNamesTheWeekAndItsShape() {
        let first = CoachNotes.weekAhead(index: 0, total: 12, phase: .base, isDeload: false, isTaper: false,
                                         runs: 3, lifts: 0, hasLong: true, hasHard: false, weeksToRace: nil, raceName: nil)
        #expect(first.hasPrefix("Week 1 of 12. Base. Three runs this week, with the long run to close it out."))
        #expect(first.contains("First week"))
        let build = CoachNotes.weekAhead(index: 4, total: 12, phase: .build, isDeload: false, isTaper: false,
                                         runs: 4, lifts: 2, hasLong: true, hasHard: true, weeksToRace: nil, raceName: nil)
        #expect(build.contains("Four runs this week, one of them quick, and the long run to close it out. Two lifts around them."))
        #expect(build.contains("easy days matter"))
        let raceWeek = CoachNotes.weekAhead(index: 11, total: 12, phase: .taper, isDeload: false, isTaper: true,
                                            runs: 3, lifts: 0, hasLong: false, hasHard: false, weeksToRace: 0, raceName: nil)
        #expect(raceWeek.contains("Taper.") && raceWeek.contains("this week"))
    }

    /// Looking back: on target, quick on an easy day, quick on a hard day, under on either, and
    /// nothing at all once the run is more than two days old or has no pace.
    @Test func lookBackJudgesAgainstTheSessionsOwnTarget() {
        let held = CoachNotes.lookBack(distanceText: "4.1 mi", paceText: "10:12 /mi", actualPaceSPerKm: 380, targetPaceSPerKm: 370, runType: .easy, daysAgo: 1)
        #expect(held == "Yesterday's 4.1 mi at 10:12 /mi held right where I want it.")
        #expect(CoachNotes.lookBack(distanceText: "4.1 mi", paceText: "9:40 /mi", actualPaceSPerKm: 340, targetPaceSPerKm: 380, runType: .easy, daysAgo: 1)?.contains("touch quick for an easy day") == true)
        #expect(CoachNotes.lookBack(distanceText: "5 mi", paceText: "7:40 /mi", actualPaceSPerKm: 285, targetPaceSPerKm: 300, runType: .tempo, daysAgo: 1)?.contains("quicker than the target") == true)
        #expect(CoachNotes.lookBack(distanceText: "5 mi", paceText: "8:20 /mi", actualPaceSPerKm: 310, targetPaceSPerKm: 290, runType: .tempo, daysAgo: 2)?.contains("own schedule") == true)
        #expect(CoachNotes.lookBack(distanceText: "5 mi", paceText: "8:20 /mi", actualPaceSPerKm: 310, targetPaceSPerKm: 290, runType: .tempo, daysAgo: 2, weekday: "Thursday") == "Thursday's 5 mi at 8:20 /mi came in under the target. Fitness shows up on its own schedule.")
        #expect(CoachNotes.lookBack(distanceText: "4 mi", paceText: "10:00 /mi", actualPaceSPerKm: 372, targetPaceSPerKm: nil, runType: nil, daysAgo: 1) == "Yesterday's 4 mi at 10:00 /mi is in the book.")
        #expect(CoachNotes.lookBack(distanceText: "4 mi", paceText: "10:00 /mi", actualPaceSPerKm: 372, targetPaceSPerKm: 370, runType: .easy, daysAgo: 3) == nil)
        #expect(CoachNotes.lookBack(distanceText: "4 mi", paceText: "--", actualPaceSPerKm: 0, targetPaceSPerKm: 370, runType: .easy, daysAgo: 1) == nil)
    }

    /// The generator writes a note onto every session that carried only the fixed fallback, and
    /// leaves the engine's special rationales alone.
    @Test func annotateReplacesOnlyTheGenericSentences() {
        var w0 = GeneratedWeek(index: 0, isDeload: false, isTaper: false, phase: .base, sessions: [])
        var easy = GeneratedSession(dayOffset: 1, discipline: .running); easy.runType = .easy; easy.targetDistanceM = 6_000; easy.targetPaceSPerKm = 380
        easy.rationale = PlanEngine.rationale(for: easy)                 // the old fixed sentence
        var long = GeneratedSession(dayOffset: 6, discipline: .running); long.runType = .long; long.targetDistanceM = 12_000; long.targetPaceSPerKm = 400
        long.rationale = nil                                             // nothing at all
        var special = GeneratedSession(dayOffset: 3, discipline: .running); special.runType = .easy; special.targetDistanceM = 5_000
        special.rationale = "Kept easy to protect recovery around your lifting."
        w0.sessions = [easy, special, long]
        var weeks = [w0]
        let inputs = PlanInputs(disciplines: [.running], goal: .endurance, daysPerWeek: 3, equipment: .bodyweight,
                                sessionMinutes: 45, raceDate: nil, runningExperience: .some, liftingExperience: .new)
        CoachNotes.annotate(&weeks, inputs: inputs, startDate: Date(), calendar: .current)
        #expect(weeks[0].sessions[0].rationale?.contains("first week") == true)
        #expect(weeks[0].sessions[1].rationale == "Kept easy to protect recovery around your lifting.")
        #expect(weeks[0].sessions[2].rationale?.isEmpty == false)
        #expect(weeks[0].sessions[2].rationale != PlanEngine.rationale(for: long))
    }

    /// Plans generated before the notes existed get theirs in place: generic fallbacks are
    /// rewritten, specific rationales and self-coached plans are untouched, and a second pass
    /// writes nothing.
    @MainActor @Test func existingPlansGetTheirNotesInPlaceOnce() throws {
        let schema = Schema(PersistenceController.models)
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let cal = Calendar(identifier: .gregorian)
        let monday = cal.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))   // 2001-01-01, a Monday
        func generic(_ type: RunType, day: Int) -> String {
            PlanEngine.rationale(for: GeneratedSession(dayOffset: day, discipline: .running, runType: type))
        }
        func run(_ week: Int, _ day: Int, _ type: RunType, km: Double, note: String?) -> PlannedSession {
            let s = PlannedSession()
            s.date = cal.date(byAdding: .day, value: week * 7 + day, to: monday)!
            s.discipline = .running; s.runType = type; s.targetDistanceM = km * 1000; s.rationale = note
            return s
        }
        let injury = "A steady run instead of repeats today. We build carefully around your injury history."
        let plan = TrainingPlan()
        plan.blockStart = monday
        plan.weekPhases = [PlanPhase.base, .base, .build, .recovery].map(\.rawValue)
        var sessions: [PlannedSession] = []
        for w in 0..<4 {
            sessions.append(run(w, 1, .easy, km: 6, note: generic(.easy, day: 1)))
            sessions.append(run(w, 3, .tempo, km: 8, note: w == 1 ? injury : generic(.tempo, day: 3)))
            sessions.append(run(w, 6, .long, km: 14 + Double(w) * 2, note: generic(.long, day: 6)))
        }
        let lift = PlannedSession()
        lift.date = cal.date(byAdding: .day, value: 2, to: monday)!
        lift.discipline = .strength; lift.strengthLabel = "Push"; lift.rationale = "Push day."
        sessions.append(lift)
        plan.sessions = sessions
        context.insert(plan)
        try context.save()

        #expect(CoachNotes.annotate(existing: plan, calendar: cal) == 12)   // everything but the injury note
        for s in plan.sessions {
            let text = s.rationale ?? ""
            #expect(!text.isEmpty)
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}") && !text.contains("-"), "\(text)")
            CoachVoiceTests.assertCoachVoice(text, "existing plan note")
        }
        #expect(plan.sessions.contains { $0.rationale == injury })
        #expect(!plan.sessions.contains { $0.rationale == generic(.easy, day: 1) })
        #expect(lift.rationale?.hasPrefix("Push day.") == true && lift.rationale != "Push day.")
        // Idempotent: nothing is generic any more.
        #expect(CoachNotes.annotate(existing: plan, calendar: cal) == 0)
        // Self-coached plans are the athlete's own words.
        let own = TrainingPlan(); own.isSelfCoached = true; own.blockStart = monday
        let mine = run(0, 1, .easy, km: 5, note: generic(.easy, day: 1))
        own.sessions = [mine]; context.insert(own)
        #expect(CoachNotes.annotate(existing: own, calendar: cal) == 0)
        #expect(mine.rationale == generic(.easy, day: 1))
    }
}
