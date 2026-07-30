import Testing
import Foundation
@testable import Momentum

/// The coach's voice, enforced.
///
/// Everything in this suite is text the athlete reads or hears: the post-workout read, the verdict
/// line, the pace review, the spoken cues. Copy drifts, and it drifts in one direction, because the
/// register that comes easiest to a machine is the one that sounds like a machine. This is the
/// tripwire.
///
/// Two rules, both learned from reading our own output:
///
/// 1. **No em dashes or en dashes.** They are the single most recognisable tell in generated
///    writing, and once you see it in a coaching app you cannot unsee it. A hyphen inside a word
///    ("3-day", "warm-up") is fine and stays fine.
/// 2. **No filler.** Praise with nothing behind it ("Nice work"), cheerleading tails ("Keep it
///    up"), throat-clearing ("That said"), and conclusions bolted onto a comma (", a strong
///    effort") are what something with nothing to say says. A coach with nothing to add stops
///    talking. The numbers are already on the screen.
@MainActor
struct CoachVoiceTests {

    /// Phrases that mean the writing gave up. Substring-matched, case-insensitive.
    static let filler = [
        "great job", "nice work", "good job", "well done", "keep it up", "keep up the",
        "you've got this", "you got this", "crushing it", "crushed it", "amazing work",
        "that said", "it's worth noting", "here's the thing", "remember to", "make sure to",
        "every step counts", "keep stacking", "strong work", "solid work", "great work",
    ]

    /// The whole voice check in one place, so every producer below is held to the same bar.
    static func assertCoachVoice(_ text: String, _ source: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!text.contains("—"), "\(source) uses an em dash: \(text)", sourceLocation: sourceLocation)
        #expect(!text.contains("–"), "\(source) uses an en dash: \(text)", sourceLocation: sourceLocation)
        #expect(!text.contains("!"), "\(source) shouts: \(text)", sourceLocation: sourceLocation)
        let lower = text.lowercased()
        for phrase in filler {
            #expect(!lower.contains(phrase),
                    "\(source) falls back on filler (\"\(phrase)\"): \(text)",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - Fixtures

    private func strengthWorkout(planned: Bool) -> Workout {
        let bench = Exercise(name: "Bench", primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        let set = SetEntry(); set.weightKg = 80; set.reps = 5; set.isComplete = true; set.type = .working
        let row = WorkoutExercise(); row.exercise = bench; row.sets = [set]
        let session = StrengthSession(); session.totalVolumeKg = 800; session.totalSets = 2; session.exercises = [row]
        let w = Workout(); w.type = .strength; w.durationS = 1800; w.strength = session
        return w
    }

    private func cardioWorkout(_ type: WorkoutType, distanceM: Double = 8000) -> Workout {
        let gps = GPSDetail(); gps.distanceM = distanceM; gps.elevationGainM = 64
        let w = Workout(); w.type = type; w.durationS = 2510; w.gps = gps
        return w
    }

    // MARK: - The post-workout read

    @Test func everyPostWorkoutReadSpeaksLikeACoach() {
        var reads: [(String, String)] = []
        for planned in [true, false] {
            for unit in [DistanceUnit.metric, .imperial] {
                for type in [WorkoutType.run, .trailRun, .walk, .hike, .ride, .yoga, .tennis] {
                    let read = WorkoutReadTemplates.read(for: cardioWorkout(type), planned: planned,
                                                         distanceUnit: unit)
                    reads.append((read.narrative, "read(\(type), planned: \(planned), \(unit))"))
                }
                let strength = WorkoutReadTemplates.read(for: strengthWorkout(planned: planned),
                                                         planned: planned, weightUnit: .kg)
                reads.append((strength.narrative, "read(strength, planned: \(planned))"))
            }
        }
        // The empty shapes too: a workout with nothing to say about it is exactly where filler creeps in.
        let bare = Workout(); bare.type = .run; bare.durationS = 600
        reads.append((WorkoutReadTemplates.read(for: bare, planned: false).narrative, "read(run, no gps)"))
        let bareLift = Workout(); bareLift.type = .strength; bareLift.durationS = 600
        reads.append((WorkoutReadTemplates.read(for: bareLift, planned: false).narrative, "read(strength, no sets)"))

        for (text, source) in reads { Self.assertCoachVoice(text, source) }
    }

    /// The session tie-in, over every prescription the plan can hand it.
    @Test func everyCoachingClauseSpeaksLikeACoach() {
        let reps = [
            RepResult(repIndex: 1, repTotal: 2, title: nil, targetPaceSPerKm: 300,
                      achievedPaceSPerKm: 298, distanceM: 400, durationS: 119),
            RepResult(repIndex: 2, repTotal: 2, title: nil, targetPaceSPerKm: 300,
                      achievedPaceSPerKm: 340, distanceM: 400, durationS: 136),
        ]
        for runType in RunType.allCases {
            for set in [[], reps] {
                guard let clause = WorkoutReadTemplates.coachingClause(runType: runType, reps: set) else { continue }
                Self.assertCoachVoice(clause, "coachingClause(\(runType), reps: \(set.count))")
                // Every clause is whole sentences, never a conclusion hung off a comma.
                #expect(!clause.contains(", the "), "clause bolts a conclusion onto a comma: \(clause)")
                #expect(!clause.contains(", a "), "clause bolts a conclusion onto a comma: \(clause)")
            }
        }
    }

    // MARK: - The verdict line

    @Test func everyRunVerdictSpeaksLikeACoach() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000)
        let run = RunVerdict.Run(date: now, distanceM: 8000, durationS: 2400)
        let priorSets: [[RunVerdict.Run]] = [
            [],                                                                         // first ever
            [.init(date: now.addingTimeInterval(-86_400), distanceM: 8000, durationS: 2600)],   // faster today
            [.init(date: now.addingTimeInterval(-86_400), distanceM: 8000, durationS: 2200)],   // slower today
            [.init(date: now.addingTimeInterval(-86_400), distanceM: 3000, durationS: 900)],    // furthest ever
            (1...4).map { .init(date: now.addingTimeInterval(Double(-$0) * 86_400),
                                distanceM: 8000, durationS: 2300) },                    // mid-pack
        ]
        for (i, priors) in priorSets.enumerated() {
            for unit in [DistanceUnit.metric, .imperial] {
                guard let v = RunVerdict.verdict(for: run, priors: priors, unit: unit) else { continue }
                Self.assertCoachVoice(v.text, "RunVerdict[\(i)](\(unit))")
            }
        }
    }

    // MARK: - The pace review

    @Test func everyPaceReviewSpeaksLikeACoach() {
        func reps(_ achieved: [Double], target: Double = 300) -> [RepResult] {
            achieved.enumerated().map { i, a in
                RepResult(repIndex: i + 1, repTotal: achieved.count, title: nil, targetPaceSPerKm: target,
                          achievedPaceSPerKm: a, distanceM: 400, durationS: a * 0.4)
            }
        }
        let cases: [(String, [RepResult])] = [
            ("onPoint", reps([300, 302, 298])),
            ("ahead", reps([280, 278, 282])),
            ("review", reps([330, 334, 331])),
            ("variable", reps([280, 340, 300, 360])),
        ]
        for (name, set) in cases {
            for unit in [DistanceUnit.metric, .imperial] {
                guard let a = SessionPaceReview.analyze(set, unit: unit) else { continue }
                Self.assertCoachVoice(a.headline, "PaceReview.\(name).headline(\(unit))")
                Self.assertCoachVoice(a.detail, "PaceReview.\(name).detail(\(unit))")
            }
        }
    }

    // MARK: - The spoken cues

    @Test func everySpokenCueSpeaksLikeACoach() {
        var cues = [
            CoachingCueBuilder.restComplete(), CoachingCueBuilder.paused(),
            CoachingCueBuilder.resumed(), CoachingCueBuilder.goalReached(),
            CoachingCueBuilder.workoutComplete(),
            CoachingCueBuilder.milestone(unitCount: 3, splitSecPerUnit: 525, unit: .imperial),
            CoachingCueBuilder.paceNudge(.tooFast), CoachingCueBuilder.paceNudge(.tooSlow),
        ]
        cues += (0..<3).map { CoachingCueBuilder.encouragement($0) }
        cues += [
            CoachingCueBuilder.stepStart(WorkoutStep(kind: .warmup, target: .duration(600))),
            CoachingCueBuilder.stepStart(WorkoutStep(kind: .cooldown, target: .duration(600))),
            CoachingCueBuilder.stepStart(WorkoutStep(kind: .recovery, target: .duration(90))),
            CoachingCueBuilder.stepStart(WorkoutStep(kind: .work, target: .distance(400),
                                                     paceSPerKm: 300, repIndex: 2, repTotal: 6)),
            CoachingCueBuilder.stepStart(WorkoutStep(kind: .work, target: .duration(600),
                                                     paceSPerKm: 300, title: "Tempo")),
        ]
        for cue in cues where !cue.isEmpty {
            Self.assertCoachVoice(cue, "CoachingCueBuilder")
        }
    }

    // MARK: - The dash guard itself

    /// `deDash` is the runtime net under everything the model writes, so it has to hold even when
    /// the model ignores the prompt entirely.
    @Test func deDashTurnsModelDashesIntoSentences() {
        #expect(WorkoutReadTemplates.deDash("Strong run — the second half was quicker")
                == "Strong run. The second half was quicker")
        #expect(WorkoutReadTemplates.deDash("8 km at 5:02 – even splits") == "8 km at 5:02. Even splits")
        // Hyphens inside words are left alone.
        #expect(WorkoutReadTemplates.deDash("A 3-day week") == "A 3-day week")
        Self.assertCoachVoice(WorkoutReadTemplates.sanitize("Nice pace — you held it"), "sanitize")
    }
}
