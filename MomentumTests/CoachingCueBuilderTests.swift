import Testing
@testable import Momentum

/// The voice-coach cue text (PRD §4.10) — deterministic, natural, no medical claims.
struct CoachingCueBuilderTests {

    @Test func milestoneSpeaksUnitAndSplitPaceImperial() {
        // 525 s/mi = 8:45 per mile.
        let cue = CoachingCueBuilder.milestone(unitCount: 3, splitSecPerUnit: 525, unit: .imperial)
        #expect(cue == "Mile 3. 8 minutes 45 seconds per mile.")
    }

    @Test func milestoneSpeaksUnitAndSplitPaceMetric() {
        // 302 s/km = 5:02 per km.
        let cue = CoachingCueBuilder.milestone(unitCount: 5, splitSecPerUnit: 302, unit: .metric)
        #expect(cue == "Kilometer 5. 5 minutes 2 seconds per kilometer.")
    }

    @Test func milestoneOmitsPaceWhenUnknown() {
        #expect(CoachingCueBuilder.milestone(unitCount: 1, splitSecPerUnit: 0, unit: .imperial) == "Mile 1.")
    }

    @Test func spokenPaceHandlesPluralsAndMissingParts() {
        #expect(CoachingCueBuilder.spokenPace(secPerUnit: 525) == "8 minutes 45 seconds")
        #expect(CoachingCueBuilder.spokenPace(secPerUnit: 480) == "8 minutes")           // exact minutes
        #expect(CoachingCueBuilder.spokenPace(secPerUnit: 45) == "45 seconds")            // under a minute
        #expect(CoachingCueBuilder.spokenPace(secPerUnit: 61) == "1 minute 1 second")     // singular
        #expect(CoachingCueBuilder.spokenPace(secPerUnit: 0) == "0 seconds")
    }

    @Test func encouragementCyclesDeterministically() {
        // Same index → same line; consecutive indices walk the list and wrap.
        #expect(CoachingCueBuilder.encouragement(0) == CoachingCueBuilder.encouragement(0))
        #expect(CoachingCueBuilder.encouragement(0) == CoachingCueBuilder.encouragement(3))
        #expect(CoachingCueBuilder.encouragement(0) != CoachingCueBuilder.encouragement(1))
        #expect(CoachingCueBuilder.encouragement(-1) == CoachingCueBuilder.encouragement(0))  // defensive clamp
    }

    @Test func workoutIntroSpeaksTheDaysShape() {
        // The coach's opening line: reps, hills-style efforts, and continuous titles all read
        // naturally, and a warm-up-led session promises the warm-up first.
        let reps = StructuredWorkoutBuilder.intervals(
            reps: 10, repTarget: .distance(400), repPace: 280, easyPace: 380,
            recoveryPace: 410, unitLabel: "400m")
        #expect(CoachingCueBuilder.workoutIntro(reps)
                == "Today: 10 repeats of 400 meters. Warm-up first. I'll call every step.")
        let hills = StructuredWorkoutBuilder.hills(reps: 8, pushS: 30, easyPace: 380)
        #expect(CoachingCueBuilder.workoutIntro(hills)
                == "Today: 8 hills, 30 seconds each. Warm-up first. I'll call every step.")
        let tempo = StructuredWorkoutBuilder.tempo(totalDistanceM: 6500, tempoPaceSPerKm: 320, easyPace: 380)!
        #expect(CoachingCueBuilder.workoutIntro(tempo)
                == "Today: Tempo run. Warm-up first. I'll call every step.")
    }

    @Test func lastRepGetsTheCoachsWords() {
        var rep = WorkoutStep(kind: .work, target: .distance(400), paceSPerKm: 280,
                              repIndex: 9, repTotal: 10)
        #expect(!CoachingCueBuilder.stepStart(rep).contains("Last one"))
        rep.repIndex = 10
        #expect(CoachingCueBuilder.stepStart(rep)
                == "Rep 10 of 10. Last one. 400 meters at your target. Go.")
    }

    @Test func surgesAreStrongNeverATarget() {
        // Fartlek is speed PLAY — the surge cue says "strong", not "at your target".
        let surge = WorkoutStep(kind: .work, target: .duration(60), paceSPerKm: 290,
                                toleranceSPerKm: 25, repIndex: 2, repTotal: 8, title: "Surge")
        #expect(CoachingCueBuilder.stepStart(surge) == "Surge 2 of 8. 1 minute strong. Go.")
    }

    @Test func fixedCuesAreConciseAndClaimFree() {
        let cues = [CoachingCueBuilder.restComplete(), CoachingCueBuilder.paused(),
                    CoachingCueBuilder.resumed(), CoachingCueBuilder.goalReached(),
                    CoachingCueBuilder.encouragement(0), CoachingCueBuilder.encouragement(1),
                    CoachingCueBuilder.encouragement(2)]
        let banned = ["injur", "pain", "diagnos", "medical"]
        for cue in cues {
            #expect(!cue.isEmpty)
            #expect(cue.split(separator: " ").count <= 8)
            for term in banned { #expect(!cue.lowercased().contains(term)) }
        }
    }
}
