import Testing
import Foundation
@testable import Momentum

/// The offline-log grammar (`WorkoutLogParser`) — every case here is a phrasing the Today
/// composer promises to read. These tests ARE the supported grammar: if a form isn't pinned
/// here, the receipt makes no promise about it.
struct WorkoutLogParserTests {

    // MARK: Cardio sentences

    @Test func paceSpeakIsNeverAPhantomDistance() {
        // "8 minute miles" is pace vernacular — reading it as an 8-mile run logged a distance
        // the athlete never stated (2026-07-23 audit).
        let r = WorkoutLogParser.parse("ran at 8 minute miles for 40 minutes")
        #expect(r.distanceM == nil)
        #expect(r.durationS.map { Int($0.rounded()) } == 40 * 60)
        let k = WorkoutLogParser.parse("held 5 minute ks for half an hour")
        #expect(k.distanceM == nil)
        #expect(k.durationS.map { Int($0.rounded()) } == 30 * 60)
    }

    @Test func paceUnitFollowsTheStatedDistanceUnit() {
        // "4 miles at 8:00 pace" is 8:00/mi even on a metric display — defaulting to the
        // display unit computed a duration off by the km/mi ratio.
        let r = WorkoutLogParser.parse("4 miles at 8:00 pace", distanceUnit: .metric)
        #expect(r.durationS.map { Int($0.rounded()) } == 4 * 8 * 60)
        let k = WorkoutLogParser.parse("10 km at 5:00 pace", distanceUnit: .imperial)
        #expect(k.durationS.map { Int($0.rounded()) } == 10 * 5 * 60)
    }

    @Test func anHourAndFifteenKeepsTheFifteen() {
        // Dictation drops the trailing "minutes" — the bare an-hour fallback swallowed the 15.
        let r = WorkoutLogParser.parse("ran for an hour and 15")
        #expect(r.durationS.map { Int($0.rounded()) } == 75 * 60)
        let plain = WorkoutLogParser.parse("ran for an hour")
        #expect(plain.durationS.map { Int($0.rounded()) } == 60 * 60)
    }

    @Test func easyMilesThisMorning() {
        let r = WorkoutLogParser.parse("Ran 5 easy miles this morning")
        #expect(r.type == .run)
        #expect(r.distanceM != nil && abs(r.distanceM! - 5 * 1609.344) < 0.5)
        #expect(r.effort == 2)
        #expect(r.timeHint == .morning)
        #expect(r.dayOffset == 0)
        #expect(r.exercises.isEmpty)
    }

    @Test func kilometersAndMinutes() {
        let r = WorkoutLogParser.parse("ran 10k in 52:30")
        let expected: Double = 52 * 60 + 30
        #expect(r.type == .run)
        #expect(r.distanceM == 10_000)
        #expect(r.durationS == expected)
    }

    @Test func fullClockDuration() {
        let r = WorkoutLogParser.parse("marathon in 3:45:12")
        let expected: Double = 3 * 3600 + 45 * 60 + 12
        #expect(r.type == .run)
        #expect(r.distanceM == 42_195)
        #expect(r.durationS == expected)
    }

    @Test func halfMarathonBeforeMarathon() {
        let r = WorkoutLogParser.parse("raced a half marathon yesterday")
        #expect(r.distanceM == 21_097.5)
        #expect(r.dayOffset == -1)
    }

    @Test func hoursWithTrailingMinutes() {
        let m80: Double = 4800, m90: Double = 5400, h2: Double = 7200
        #expect(WorkoutLogParser.parse("rode 1 hour 20").durationS == m80)
        #expect(WorkoutLogParser.parse("biked for 1.5 hours").durationS == m90)
        #expect(WorkoutLogParser.parse("walked 2 hrs easy").durationS == h2)
    }

    @Test func spokenHourForms() {
        let h1: Double = 3600, m30: Double = 1800, m90: Double = 5400
        #expect(WorkoutLogParser.parse("swam for an hour").durationS == h1)
        #expect(WorkoutLogParser.parse("yoga for half an hour").durationS == m30)
        #expect(WorkoutLogParser.parse("hiked an hour and a half").durationS == m90)
    }

    @Test func bareDistanceDefaultsToRun() {
        // Running-first: "did 6 miles" with no sport verb is a run.
        let r = WorkoutLogParser.parse("did 6 miles this afternoon")
        #expect(r.type == .run)
        #expect(r.timeHint == .afternoon)
    }

    @Test func sportKeywordsMap() {
        #expect(WorkoutLogParser.parse("treadmill 30 min").type == .run)
        #expect(WorkoutLogParser.parse("treadmill 30 min").indoor)
        #expect(WorkoutLogParser.parse("mountain bike ride 90 min").type == .mountainBikeRide)
        #expect(WorkoutLogParser.parse("45 min on the peloton").indoor)
        #expect(WorkoutLogParser.parse("went for a trail run").type == .trailRun)
        #expect(WorkoutLogParser.parse("played tennis for an hour").type == .tennis)
        #expect(WorkoutLogParser.parse("30 min on the erg").type == .rowing)
    }

    @Test func wordBoundariesDontMisfire() {
        // "ran" inside "grand", "run" inside "brunch" — never a sport.
        let r = WorkoutLogParser.parse("grand brunch")
        #expect(r.type == nil)
        #expect(r.isEmpty)
    }

    @Test func earliestSportWins() {
        // The first thing said is the workout being logged.
        #expect(WorkoutLogParser.parse("lifted for 45 min then a short bike").type == .strength)
        #expect(WorkoutLogParser.parse("biked 40 min then lifted").type == .ride)
    }

    @Test func intervalRepeatsAreNotDistance() {
        // "5 x 1k" is a rep scheme, not a 1 km run.
        let r = WorkoutLogParser.parse("track workout, 5 x 1k")
        #expect(r.distanceM == nil)
    }

    // MARK: Strength sentences

    @Test func classicSetLine() {
        let r = WorkoutLogParser.parse("bench 4x8 at 185", weightUnit: .lb)
        #expect(r.type == .strength)
        #expect(r.exercises.count == 1)
        let e = r.exercises[0]
        #expect(e.name == "Bench")
        #expect(e.sets == 4 && e.reps == 8)
        #expect(e.weightKg != nil && abs(e.weightKg! - 185 * 0.45359237) < 0.01)
    }

    @Test func fullLiftSentence() {
        let r = WorkoutLogParser.parse("45 min upper body, bench press 4x8 at 185, rows 3x10 at 135", weightUnit: .lb)
        let m45: Double = 2700
        #expect(r.type == .strength)
        #expect(r.durationS == m45)
        #expect(r.exercises.count == 2)
        #expect(r.exercises[0].name == "Bench Press")
        #expect(r.exercises[1].name == "Rows")
        #expect(r.exercises[1].sets == 3 && r.exercises[1].reps == 10)
    }

    @Test func setsOfGrammar() {
        let b = WorkoutLogParser.parse("3 sets of 12 curls at 30", weightUnit: .lb).exercises
        #expect(b.count == 1 && b[0].name == "Curls" && b[0].sets == 3 && b[0].reps == 12)
        let c = WorkoutLogParser.parse("squats 5 sets of 5 at 100kg", weightUnit: .lb).exercises
        #expect(c.count == 1 && c[0].name == "Squats" && c[0].weightKg == 100)
        let d = WorkoutLogParser.parse("did 5x5 deadlifts at 315", weightUnit: .lb).exercises
        #expect(d.count == 1 && d[0].name == "Deadlifts" && d[0].sets == 5 && d[0].reps == 5)
    }

    @Test func explicitUnitBeatsDefault() {
        let kg = WorkoutLogParser.parse("press 3x5 at 60 kg", weightUnit: .lb).exercises
        #expect(kg[0].weightKg == 60)
        let lb = WorkoutLogParser.parse("press 3x5 at 135 lbs", weightUnit: .kg).exercises
        #expect(lb[0].weightKg != nil && abs(lb[0].weightKg! - 135 * 0.45359237) < 0.01)
    }

    @Test func bodyweightAndDecimalWeights() {
        let pu = WorkoutLogParser.parse("pushups 3x15").exercises
        #expect(pu.count == 1 && pu[0].weightKg == nil)
        let db = WorkoutLogParser.parse("curls 3x12 at 22.5 kg").exercises
        #expect(db.count == 1 && db[0].weightKg == 22.5)
    }

    @Test func liftWordsImplyStrength() {
        // No sport verb at all — the exercise names carry the sport.
        let r = WorkoutLogParser.parse("bench and squats for an hour")
        #expect(r.type == .strength)
        #expect(r.durationS == 3600)
    }

    @Test func cardioSentencesDropSetNoise() {
        // A rep scheme inside a run ("4x400s") must not become gym exercises.
        let r = WorkoutLogParser.parse("ran 4 x 400 on the track, 30 min total")
        #expect(r.type == .run)
        #expect(r.exercises.isEmpty)
    }

    @Test func absurdWeightRejected() {
        let r = WorkoutLogParser.parse("bench 3x5 at 5000", weightUnit: .kg).exercises
        #expect(r.count == 1 && r[0].weightKg == nil)
    }

    // MARK: Spoken numbers + gym lingo

    @Test func spokenNumbersNormalize() {
        #expect(WorkoutLogParser.normalizeSpokenNumbers("one eighty five") == "185")
        #expect(WorkoutLogParser.normalizeSpokenNumbers("two twenty five for five") == "225 for 5")
        #expect(WorkoutLogParser.normalizeSpokenNumbers("three fifteen") == "315")
        #expect(WorkoutLogParser.normalizeSpokenNumbers("forty five minutes") == "45 minutes")
        #expect(WorkoutLogParser.normalizeSpokenNumbers("twenty-five reps") == "25 reps")
        #expect(WorkoutLogParser.normalizeSpokenNumbers("two hundred and ten") == "210")
        #expect(WorkoutLogParser.normalizeSpokenNumbers("ten reps with five sets") == "10 reps with 5 sets")
        // Non-number hyphens survive.
        #expect(WorkoutLogParser.normalizeSpokenNumbers("rode the e-bike") == "rode the e-bike")
    }

    @Test func weightFirstLingo() {
        // "one eighty five for ten reps with five sets" — the sentence the feature was asked for.
        let r = WorkoutLogParser.parse("bench pressed one eighty five for ten reps with five sets", weightUnit: .lb)
        #expect(r.type == .strength)
        #expect(r.exercises.count == 1)
        let e = r.exercises[0]
        #expect(e.name == "Bench Press")
        #expect(e.sets == 5 && e.reps == 10)
        #expect(e.weightKg != nil && abs(e.weightKg! - 185 * 0.45359237) < 0.01)
    }

    @Test func topSetIdiom() {
        // No set count said → ONE top set, never an invented scheme.
        let r = WorkoutLogParser.parse("squatted 225 for 5", weightUnit: .lb)
        #expect(r.type == .strength)
        #expect(r.exercises.count == 1)
        #expect(r.exercises[0].name == "Squat")
        #expect(r.exercises[0].sets == 1 && r.exercises[0].reps == 5)
    }

    @Test func weightFirstSetsOf() {
        let r = WorkoutLogParser.parse("bench 185 for 5 sets of 10", weightUnit: .lb).exercises
        #expect(r.count == 1 && r[0].sets == 5 && r[0].reps == 10)
        // "for 5 sets" with no reps stated → no invented set line.
        #expect(WorkoutLogParser.parse("bench 185 for 5 sets", weightUnit: .lb).exercises.isEmpty)
    }

    // MARK: Pace + multi-workout

    @Test func paceDerivesDuration() {
        let r = WorkoutLogParser.parse("ran 4 miles at 9:23 pace", distanceUnit: .imperial)
        let expected: Double = (9 * 60 + 23) * 4
        #expect(r.type == .run)
        #expect(r.durationS == expected)
        // Spoken: "a nine twenty three pace" normalizes to "923 pace" — same read.
        let s = WorkoutLogParser.parse("ran 4 miles at around a nine twenty three pace", distanceUnit: .imperial)
        #expect(s.durationS == expected)
        // An explicit duration always beats a derived one.
        let d = WorkoutLogParser.parse("ran 4 miles in 40:00 at 9:23 pace", distanceUnit: .imperial)
        #expect(d.durationS == 2400)
    }

    @Test func multiWorkoutSplits() {
        let list = WorkoutLogParser.parseMulti(
            "45 min upper body, bench 4x8 at 185, then ran 4 miles at 9:23 pace",
            weightUnit: .lb, distanceUnit: .imperial)
        #expect(list.count == 2)
        #expect(list[0].type == .strength)
        #expect(list[0].durationS == 2700)
        #expect(list[0].exercises.count == 1)
        #expect(list[1].type == .run)
        #expect(list[1].distanceM != nil && abs(list[1].distanceM! - 4 * 1609.344) < 0.5)
        #expect(list[1].durationS != nil)   // pace × distance
    }

    @Test func footnoteMentionDoesNotSplit() {
        // "then a short bike" brings no numbers — it's a footnote, not a second card.
        let list = WorkoutLogParser.parseMulti("lifted for 45 min then a short bike")
        #expect(list.count == 1)
        #expect(list[0].type == .strength)
    }

    @Test func namedLiftAfterCardioSplits() {
        // "bench"/"squats" aren't sport verbs, but they mean the gym — without hint-splitting the
        // whole lift silently drowned in the walk card (battery-caught bug).
        let list = WorkoutLogParser.parseMulti(
            "walked the dog for 30 min then bench 3x10 at 135 and squats 3x8 at 185",
            weightUnit: .lb)
        #expect(list.count == 2)
        #expect(list[0].type == .walk)
        #expect(list[0].durationS == 1800)
        #expect(list[1].type == .strength)
        #expect(list[1].exercises.count == 2)
    }

    @Test func andAHalfAndRepIdioms() {
        let r = WorkoutLogParser.parse("ran four and a half miles easy", distanceUnit: .imperial)
        #expect(r.distanceM != nil && abs(r.distanceM! - 4.5 * 1609.344) < 0.5)
        let d = WorkoutLogParser.parse("deadlifted 315 for a triple", weightUnit: .lb)
        #expect(d.exercises.count == 1)
        #expect(d.exercises[0].sets == 1 && d.exercises[0].reps == 3)
        #expect(WorkoutLogParser.parse("quick 20 min core session").type == .strength)
    }

    @Test func stackedDatesOrderHistory() {
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 21, minute: 0, second: 0, of: Date())!
        var lift = WorkoutLogParser.Result()
        lift.type = .strength
        lift.durationS = 3000
        var run = WorkoutLogParser.Result()
        run.type = .run
        run.durationS = 2252
        // Now-anchored: the run (said last) is most recent; the lift stacks backward before it.
        let backward = WorkoutLogParser.stackedDates(for: [lift, run], now: now, calendar: cal)
        #expect(backward[1] == now)
        #expect(backward[0] < backward[1])
        #expect(abs(backward[1].timeIntervalSince(backward[0]) - (3000 + 300)) < 1)
        // Anchored ("this morning" → 7:00): stack forward from the anchor.
        var liftAM = lift
        liftAM.timeHint = .morning
        var runAM = run
        runAM.timeHint = .morning
        let forward = WorkoutLogParser.stackedDates(for: [liftAM, runAM], now: now, calendar: cal)
        #expect(cal.component(.hour, from: forward[0]) == 7)
        #expect(forward[1] > forward[0])
    }

    @Test func whenWordsCarryAcrossCards() {
        let list = WorkoutLogParser.parseMulti("yesterday morning I lifted for 40 min, then ran 3 miles")
        #expect(list.count == 2)
        #expect(list[1].dayOffset == -1)
        #expect(list[1].timeHint == .morning)
    }

    // MARK: Effort + when

    @Test func effortWords() {
        #expect(WorkoutLogParser.parse("ran 5 miles hard").effort == 8)
        #expect(WorkoutLogParser.parse("really hard tempo").effort == 9)
        #expect(WorkoutLogParser.parse("went all out").effort == 10)
        #expect(WorkoutLogParser.parse("steady 10k").effort == 4)
        #expect(WorkoutLogParser.parse("recovery jog").effort == 2)
        #expect(WorkoutLogParser.parse("ran 5 miles").effort == nil)
    }

    @Test func whenWords() {
        #expect(WorkoutLogParser.parse("ran last night").dayOffset == -1)
        #expect(WorkoutLogParser.parse("ran last night").timeHint == .evening)
        #expect(WorkoutLogParser.parse("lifted yesterday morning").dayOffset == -1)
        #expect(WorkoutLogParser.parse("lifted yesterday morning").timeHint == .morning)
    }

    @Test func resolveDateNeverFuture() {
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        // "tonight" said at noon can't produce a 7 PM start that hasn't happened.
        let d = WorkoutLogParser.resolveDate(dayOffset: 0, timeHint: .evening, now: noon, calendar: cal)
        #expect(d <= noon)
        // "this morning" said at noon pins to 7 AM today.
        let m = WorkoutLogParser.resolveDate(dayOffset: 0, timeHint: .morning, now: noon, calendar: cal)
        #expect(cal.component(.hour, from: m) == 7)
        #expect(cal.isDate(m, inSameDayAs: noon))
        // "yesterday" with no time keeps the clock, a day back.
        let y = WorkoutLogParser.resolveDate(dayOffset: -1, timeHint: nil, now: noon, calendar: cal)
        #expect(cal.component(.hour, from: y) == 12)
        #expect(!cal.isDate(y, inSameDayAs: noon))
    }

    // MARK: Emptiness — the receipt only appears when something real was read

    @Test func noiseStaysEmpty() {
        #expect(WorkoutLogParser.parse("").isEmpty)
        #expect(WorkoutLogParser.parse("   ").isEmpty)
        #expect(WorkoutLogParser.parse("hello there").isEmpty)
        #expect(!WorkoutLogParser.parse("ran").isEmpty)
    }
}
