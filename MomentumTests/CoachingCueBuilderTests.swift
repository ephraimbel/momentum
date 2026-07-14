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
