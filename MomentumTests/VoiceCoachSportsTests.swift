import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The voice coach's PER-SPORT contract.
///
/// `LiveCoachCadenceTests` pins what a run hears and when. This pins the other half of the promise:
/// that every workout the app can record is coached in words that sport can actually measure — a
/// ride in speed, a gym session in sets and rests, a tennis match on the clock, a guided session
/// step by step — and that nothing is left mute. Each test below is a defect that shipped or a
/// defect that would have.
@Suite("VoiceCoachSports")
struct VoiceCoachSportsTests {

    // MARK: The register — which vocabulary each sport gets

    /// The capture mode decides the vocabulary, and the flags are mutually exclusive by contract.
    /// The stationary e-bike is the case that proves it: it is `isCycling` AND `isTimed`, and
    /// coaching it as a ride promised splits down a road it never travels.
    @Test func everySportSpeaksInTheRegisterItsCaptureModeCanMeasure() {
        for type in WorkoutType.allCases {
            let speech = CoachSpeech.forType(type)
            if type.isStrengthStyle { #expect(speech == .strength) }
            else if type.isTimed { #expect(speech == .timed) }
            else if type.isCycling { #expect(speech == .ride) }
            else if type == .walk || type == .hike { #expect(speech == .walk) }
            else { #expect(speech == .run) }
            // A register that calls ground covered may only be given to a sport that measures it.
            #expect(speech.callsDistance == type.isGPS)
        }
        #expect(CoachSpeech.forType(.eBikeRide) == .timed)
    }

    /// The bug a rider reported as "it just says the mile number": a split IS a speed once you
    /// divide it into an hour, and dropping the figure instead of converting it left every ride
    /// milestone a bare noun.
    @Test func aRideCallsSpeedAndEveryFootSportCallsPace() {
        // 4:00 per kilometre = 15.0 km/h.
        let rideKm = CoachingCueBuilder.milestone(unitCount: 10, splitSecPerUnit: 240,
                                                  unit: .metric, speech: .ride)
        #expect(rideKm == "Kilometer 10. 15 kilometers per hour.")
        for speech in [CoachSpeech.run, .walk] {
            #expect(CoachingCueBuilder.milestone(unitCount: 3, splitSecPerUnit: 525, unit: .imperial,
                                                 speech: speech) == "Mile 3. 8:45 per mile.")
        }
        // An unknown split is still a milestone worth calling — in every register.
        for speech in CoachSpeech.allCases {
            #expect(CoachingCueBuilder.milestone(unitCount: 2, splitSecPerUnit: 0, unit: .metric,
                                                 speech: speech) == "Kilometer 2.")
        }
    }

    /// A ride's opening line is in the rider's instrument too — the plan's pace becomes a speed.
    @Test func aPlannedRideOpensInSpeedAndAPlannedRunInPace() {
        let ride = CoachingCueBuilder.runIntro(goalMeters: 40_000, targetPaceSPerKm: 120,
                                               unit: .metric, speech: .ride)
        #expect(ride == "40 kilometers today. Hold about 30 kilometers per hour.")
        let run = CoachingCueBuilder.runIntro(goalMeters: 14 * Formatters.metersPerMile,
                                              targetPaceSPerKm: 360, unit: .imperial, speech: .run)
        #expect(run == "14 miles today. Hold about 9:40 per mile.")
        // No goal, no opening line: silence is the norm on a free run.
        #expect(CoachingCueBuilder.runIntro(goalMeters: nil, targetPaceSPerKm: 360,
                                            unit: .imperial, speech: .run) == nil)
    }

    /// A yoga mat and a bench press have no tape. Handing them a distance line would be the coach
    /// inventing a measurement the session never took.
    @Test func aStopwatchOrGymSessionIsNeverToldADistance() {
        for speech in [CoachSpeech.timed, .strength] {
            #expect(speech.callsDistance == false)
            #expect(CoachingCueBuilder.runIntro(goalMeters: 8_000, targetPaceSPerKm: 300,
                                                unit: .metric, speech: speech) == nil)
        }
    }

    // MARK: Stopwatch sports — the clock is the only thing they measure

    private func replay(_ type: WorkoutType, minutes: Int) -> [String] {
        var coach = TimedCoach(type: type)
        var out: [String] = []
        for second in 1...(minutes * 60) {
            if let line = coach.tick(elapsedS: Double(second), paused: false) { out.append(line.text) }
        }
        return out
    }

    /// A calm room is not an erg. Yoga hears the clock four times in an hour; a rower between
    /// pieces hears it twelve.
    @Test func eachStopwatchSportIsCalledOnItsOwnInterval() {
        #expect(replay(.yoga, minutes: 60) == ["15 minutes in.", "30 minutes in.",
                                               "45 minutes in.", "1 hour in."])
        #expect(replay(.rowing, minutes: 20) == ["5 minutes in.", "10 minutes in.",
                                                 "15 minutes in.", "20 minutes in."])
        #expect(replay(.tennis, minutes: 70) == ["10 minutes in.", "20 minutes in.", "30 minutes in.",
                                                 "40 minutes in.", "50 minutes in.", "1 hour in.",
                                                 "1 hour 10 minutes in."])
        // Every stopwatch sport is coached — none falls through to silence.
        for type in WorkoutType.allCases where type.isTimed {
            #expect(TimedCoach.intervalS(for: type) >= 300)
            #expect(!replay(type, minutes: 20).isEmpty)
        }
    }

    /// The app can be suspended for minutes at a time and the ticker slips with it. A late tick
    /// must not drag every later call off the grid behind it.
    @Test func aLateTickSnapsBackToTheGridInsteadOfDriftingForever() {
        var coach = TimedCoach(type: .tennis)
        #expect(coach.tick(elapsedS: 1_500, paused: false)?.text == "20 minutes in.")   // 25 min in
        #expect(coach.tick(elapsedS: 1_501, paused: false) == nil)
        #expect(coach.tick(elapsedS: 1_800, paused: false)?.text == "30 minutes in.")
    }

    /// A match that stops for twenty minutes resumes at the minute it left: the coach is told
    /// ACTIVE time, and says nothing at all while the clock is held.
    @Test func aPausedMatchSaysNothingAndResumesWhereItLeftOff() {
        var coach = TimedCoach(type: .basketball)
        #expect(coach.tick(elapsedS: 600, paused: false)?.text == "10 minutes in.")
        for _ in 0..<50 { #expect(coach.tick(elapsedS: 900, paused: true) == nil) }
        #expect(coach.tick(elapsedS: 1_100, paused: false) == nil)      // still inside the interval
        #expect(coach.tick(elapsedS: 1_200, paused: false)?.text == "20 minutes in.")
    }

    /// The opening and closing lines name the sport and its one number, for every stopwatch sport.
    @Test func everyStopwatchSportOpensAndClosesWithARealSentence() {
        for type in WorkoutType.allCases where type.isTimed {
            let coach = TimedCoach(type: type)
            let intro = coach.intro().text
            #expect(intro == "\(type.title). Recording.")
            #expect(!intro.contains("  ") && !intro.lowercased().contains("nil"))
            #expect(coach.complete(elapsedS: 75 * 60).text == "Done. 1 hour 15 minutes.")
        }
        // A session too short to have a minute in it still gets an ending.
        #expect(TimedCoach(type: .golf).complete(elapsedS: 12).text == "Done.")
    }

    // MARK: The gym

    /// "Rest complete" on its own does not earn speaking in a gym — the whole point is that the
    /// phone stays on the floor, which needs the exercise and the set number.
    @Test func theRestCueNamesTheSetThatIsOwed() {
        #expect(CoachingCueBuilder.restStart(seconds: 90) == "Rest 1 minute 30 seconds.")
        #expect(CoachingCueBuilder.restStart(seconds: 0).isEmpty)
        #expect(CoachingCueBuilder.restComplete(next: "Bench press", setNumber: 3)
                == "Rest complete. Bench press, set 3.")
        #expect(CoachingCueBuilder.restComplete(next: "Bench press")
                == "Rest complete. Bench press next.")
        #expect(CoachingCueBuilder.restComplete() == "Rest complete. Time for your next set.")
        // An empty name is not a name — it must fall back rather than say "Rest complete. , set 2."
        #expect(CoachingCueBuilder.restComplete(next: "", setNumber: 2)
                == "Rest complete. Time for your next set.")
    }

    // MARK: The numerals themselves

    /// Both spoken numbers are derived, not stored: a speed is a split turned inside out, and the
    /// clock is seconds folded into hours. Every degenerate input below produced a sentence at some
    /// point ("0 miles per hour", "75 minutes in"), and a coach that says one of those is broken
    /// more visibly than one that says nothing.
    @Test func theSpokenNumeralsRefuseNonsense() {
        #expect(CoachingCueBuilder.spokenSpeed(secPerUnit: 225, unit: .imperial) == "16 miles per hour")
        #expect(CoachingCueBuilder.spokenSpeed(secPerUnit: 202, unit: .imperial) == "17.8 miles per hour")
        #expect(CoachingCueBuilder.spokenSpeed(secPerUnit: 180, unit: .metric) == "20 kilometers per hour")
        for bad in [0.0, -5, .infinity, .nan, 100_000] {
            #expect(CoachingCueBuilder.spokenSpeed(secPerUnit: bad, unit: .imperial).isEmpty,
                    "a split of \(bad) is not a speed")
        }

        #expect(CoachingCueBuilder.spokenMinutes(0) == "0 minutes")
        #expect(CoachingCueBuilder.spokenMinutes(1) == "1 minute")
        #expect(CoachingCueBuilder.spokenMinutes(45) == "45 minutes")
        #expect(CoachingCueBuilder.spokenMinutes(60) == "1 hour")
        #expect(CoachingCueBuilder.spokenMinutes(75) == "1 hour 15 minutes")
        #expect(CoachingCueBuilder.spokenMinutes(120) == "2 hours")
        #expect(CoachingCueBuilder.spokenMinutes(121) == "2 hours 1 minute")
        #expect(CoachingCueBuilder.spokenMinutes(-10) == "0 minutes")
    }

    @Test func theSessionLineCountsTheWorkAndAgreesWithItsOwnNumber() {
        #expect(CoachingCueBuilder.strengthComplete(sets: 1) == "Session complete. 1 set logged.")
        #expect(CoachingCueBuilder.strengthComplete(sets: 14) == "Session complete. 14 sets logged.")
        #expect(CoachingCueBuilder.strengthComplete(sets: 0) == "Session complete.")
    }

    // MARK: Guided sessions — every workout in the library, spoken

    private func libraryWorkouts() -> [(id: String, workout: StructuredWorkout)] {
        WorkoutLibrary.all.compactMap { entry in
            let rx = WorkoutLibrary.prescription(entry, p5k: 300, unit: .metric)
            guard let w = StructuredWorkoutBuilder.build(from: rx.makeSession(on: .now),
                                                         p5kSPerKm: 300, raceDistanceM: 42_195)
            else { return nil }
            return (entry.id, w)
        }
    }

    /// The catalog is data and it grows. Every entry in it must have an opening line and a spoken
    /// call for every step it contains — no silent step, no half-built sentence.
    @Test func everyLibraryWorkoutSpeaksItsOpeningLineAndEveryStep() {
        let workouts = libraryWorkouts()
        #expect(workouts.count == WorkoutLibrary.all.count)   // every entry expands (and so speaks)

        var broken: [String] = []
        for (id, workout) in workouts {
            let intro = CoachingCueBuilder.workoutIntro(workout)
            if !intro.hasPrefix("Today: ") || !intro.hasSuffix("I'll call every step.")
                || intro.contains("  ") || intro.contains("nil") || intro.contains("Optional") {
                broken.append("\(id) intro: \(intro)")
            }
            for step in workout.steps {
                let line = CoachingCueBuilder.stepStart(step)
                if line.isEmpty || line.contains("  ") || line.hasPrefix(" ") || line.hasPrefix(".")
                    || line.contains("nil") || line.contains("Optional") || !line.hasSuffix(".") {
                    broken.append("\(id) step: \(line)")
                }
            }
        }
        #expect(broken.isEmpty, "\(broken)")
    }

    /// The words a coach actually uses at the track, per step shape. These are the exact sentences
    /// the athlete hears on each of the library's structural forms.
    @Test func everyGuidedStepFormReadsAsACoachWouldSayIt() {
        // Track reps: numbered, paced, and the last one is called the way every coach calls it.
        let reps = StructuredWorkoutBuilder.intervals(reps: 6, repTarget: .distance(400), repPace: 240,
                                                      easyPace: 360, recoveryPace: 400, unitLabel: "400m")
        #expect(CoachingCueBuilder.workoutIntro(reps)
                == "Today: 6 repeats of 400 meters. Warm-up first. I'll call every step.")
        let repSteps = reps.steps.filter { $0.kind == .work }
        #expect(CoachingCueBuilder.stepStart(repSteps[0]) == "Rep 1 of 6. 400 meters at your target. Go.")
        #expect(CoachingCueBuilder.stepStart(repSteps[5]) == "Rep 6 of 6. Last one. 400 meters at your target. Go.")
        #expect(CoachingCueBuilder.stepStart(reps.steps[0]) == "Warm up. Ease in.")
        #expect(CoachingCueBuilder.stepStart(reps.steps.last!) == "Cool down. Nice and easy.")

        // Hills have no pace target — a grade destroys pace, so they are called by effort.
        let hills = StructuredWorkoutBuilder.hills(reps: 8, pushS: 45, easyPace: 360)
        #expect(CoachingCueBuilder.workoutIntro(hills)
                == "Today: 8 hills, 45 seconds each. Warm-up first. I'll call every step.")
        #expect(CoachingCueBuilder.stepStart(hills.steps[1]) == "Hill 1 of 8. 45 seconds hard. Go.")
        // 45 s pushes take the builder's 90 s recovery FLOOR, not 45 x 1.6 = 72: "a hard push earns
        // a real reset". The spoken line has to agree with the step the athlete is actually running.
        #expect(CoachingCueBuilder.stepStart(hills.steps[2]) == "Jog down. 1 minute 30 seconds easy.")

        // A fartlek surge is speed PLAY: "strong", never a number to chase.
        let fartlek = StructuredWorkoutBuilder.fartlek(reps: 8, onS: 60, floatS: 60,
                                                       hardPace: 240, floatPace: 360)
        #expect(CoachingCueBuilder.stepStart(fartlek.steps[1]) == "Surge 1 of 8. 1 minute strong. Go.")
        #expect(CoachingCueBuilder.stepStart(fartlek.steps[2]) == "Float. 1 minute easy.")

        // Strides: practice, not load.
        let strides = StructuredWorkoutBuilder.strides(reps: 6, strideS: 20, easyPace: 360,
                                                       totalDistanceM: 8_000)
        #expect(CoachingCueBuilder.stepStart(strides.steps[1]) == "Stride 1 of 6. 20 seconds hard. Go.")
        #expect(CoachingCueBuilder.stepStart(strides.steps[2]) == "Walk back. 1 minute easy.")

        // Continuous blocks are named by what they are, and hold an effort rather than chase a rep.
        let tempo = StructuredWorkoutBuilder.tempo(totalDistanceM: 10_000, tempoPaceSPerKm: 270,
                                                   easyPace: 360)!
        #expect(CoachingCueBuilder.stepStart(tempo.steps[1]) == "8 kilometers. Hold your effort.")
        let progression = StructuredWorkoutBuilder.progression(totalDistanceM: 9_000, easyPace: 360,
                                                               moderatePace: 320, strongPace: 280)!
        #expect(progression.steps.map { CoachingCueBuilder.stepStart($0) }
                == ["Easy. 3 kilometers. Hold your effort.",
                    "Moderate. 3 kilometers. Hold your effort.",
                    "Strong. 3 kilometers. Hold your effort."])
        let long = StructuredWorkoutBuilder.raceFinishLong(totalDistanceM: 24_000, finishM: 5_000,
                                                           bodyPace: 360, racePace: 300)!
        #expect(CoachingCueBuilder.stepStart(long.steps[1]) == "Race pace. 5 kilometers. Hold your effort.")

        // Run/walk is a beginner's session: named plainly, never told to pick it up.
        let runWalk = StructuredWorkoutBuilder.runWalk(runS: 60, walkS: 90, runPaceSPerKm: 400,
                                                       totalDistanceM: nil, totalDurationS: 1_800)
        #expect(CoachingCueBuilder.stepStart(runWalk.steps[0]) == "Run. 1 minute. Hold your effort.")
        #expect(CoachingCueBuilder.stepStart(runWalk.steps[1]) == "Walk. 1 minute 30 seconds easy.")
    }

    /// Nudges are directions, never verdicts — and there is nothing to say to someone on pace or
    /// running a step with no target at all (a hill, a stride, a walk break).
    @Test func aNudgeIsOnlyEverADirection() {
        #expect(CoachingCueBuilder.paceNudge(.tooFast) == "Ease back a touch.")
        #expect(CoachingCueBuilder.paceNudge(.tooSlow) == "Pick it up.")
        #expect(CoachingCueBuilder.paceNudge(.onPace).isEmpty)
        #expect(CoachingCueBuilder.paceNudge(.noTarget).isEmpty)
        #expect(CoachingCueBuilder.paceDrift(.onPace).isEmpty)
        #expect(CoachingCueBuilder.paceDrift(.noTarget).isEmpty)
        // An empty line is dropped by the gate rather than "spoken" as silence.
        var gate = CoachCueGate()
        #expect(gate.admit(.init(text: "", priority: .transition), at: 0) == .drop)
    }
}
