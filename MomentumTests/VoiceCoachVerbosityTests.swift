import Testing
import Foundation
@testable import Momentum

/// The verbosity dial (`CoachVerbosity`) and the two cues that arrived with it: the "10 seconds"
/// call before a timed step ends, and the heart-rate zone on a split at Full.
///
/// The contract worth pinning: the structure of a session is spoken at EVERY level, the dial only
/// ever removes numbers, and the filter lives in one place (`VoiceCoachServing.announce(_:kind:)`)
/// so no sport can forget it.
@Suite("VoiceCoachVerbosity")
struct VoiceCoachVerbosityTests {
    typealias Kind = CoachCueGate.Line.Kind
    private static let everyKind: [Kind] = [.intro, .split, .halfway, .finalStretch, .goal, .nudge,
                                            .encouragement, .stepStart, .stepWarning, .complete, .other]
    private static let structure: [Kind] = [.intro, .stepStart, .goal, .complete, .other]

    // MARK: The dial

    /// The default is the coach exactly as it shipped: every kind spoken, no zone. Full changes one
    /// thing only, and Minimal can never silence a step change.
    @Test func standardIsTheCoachAsShippedAndFullOnlyAddsTheZone() {
        #expect(CoachVerbosity.default == .standard)
        for kind in Self.everyKind {
            #expect(CoachVerbosity.standard.speaks(kind))
            #expect(CoachVerbosity.full.speaks(kind) == CoachVerbosity.standard.speaks(kind))
        }
        #expect(!CoachVerbosity.standard.speaksZone)
        #expect(!CoachVerbosity.minimal.speaksZone)
        #expect(CoachVerbosity.full.speaksZone)
    }

    /// Minimal keeps the words that change the workout and drops every number. `.other` stays: it
    /// is the kind of the ad-hoc transitions (pause, resume, the gym's rests).
    @Test func minimalStillCallsTheStructureOfTheSession() {
        for kind in Self.everyKind {
            #expect(CoachVerbosity.minimal.speaks(kind) == Self.structure.contains(kind),
                    "minimal.speaks(\(kind)) wrong")
        }
    }

    /// An unknown stored value must read as the default, never as silence.
    @Test func unknownRawValueIsNotALevel() {
        #expect(CoachVerbosity(rawValue: "loud") == nil)
        #expect(CoachVerbosity.allCases.map(\.rawValue) == ["minimal", "standard", "full"])
        for level in CoachVerbosity.allCases { #expect(!level.title.isEmpty); #expect(!level.blurb.isEmpty) }
    }

    /// The filter is the protocol's, not any one sport's: a conformer that only implements the
    /// unconditional `announce(_:)` gets the dial for free on the kinded call, and the unconditional
    /// call stays unconditional (the gym's rests, a pause).
    @MainActor
    @Test func theDialIsHonouredInOnePlaceForEveryConformer() {
        @MainActor final class Spy: VoiceCoachServing {
            var isEnabled = true
            var verbosity: CoachVerbosity = .standard
            var spoken: [String] = []
            func announce(_ text: String) { spoken.append(text) }
            func stop() {}
        }
        let voice = Spy()
        voice.announce("Mile 1.", kind: .split)
        voice.announce("Rep 1 of 6. Go.", kind: .stepStart)
        #expect(voice.spoken == ["Mile 1.", "Rep 1 of 6. Go."])

        voice.verbosity = .minimal
        voice.announce("Mile 2.", kind: .split)
        voice.announce("Pick it up.", kind: .nudge)
        voice.announce("10 seconds.", kind: .stepWarning)
        voice.announce("Rep 2 of 6. Go.", kind: .stepStart)
        voice.announce("Paused.")                                  // unconditional
        #expect(voice.spoken == ["Mile 1.", "Rep 1 of 6. Go.", "Rep 2 of 6. Go.", "Paused."])
    }

    // MARK: "10 seconds."

    /// Once per step, at the moment: nothing above ten seconds to go, the line at ten, nothing
    /// again for that step, and the next step re-arms it.
    @Test func stepEndingFiresOnceAtTenSecondsAndReArmsPerStep() {
        var coach = LiveRunCoach(unit: .metric)
        #expect(coach.stepEnding(stepIndex: 1, stepDurationS: 90, remainingS: 10.4, paused: false) == nil)
        let line = coach.stepEnding(stepIndex: 1, stepDurationS: 90, remainingS: 10.0, paused: false)
        #expect(line?.text == "10 seconds.")
        #expect(line?.kind == .stepWarning)
        #expect(coach.stepEnding(stepIndex: 1, stepDurationS: 90, remainingS: 9, paused: false) == nil)
        #expect(coach.stepEnding(stepIndex: 1, stepDurationS: 90, remainingS: 8, paused: false) == nil)
        // Next step (a rep after the recovery): armed again.
        #expect(coach.stepEnding(stepIndex: 2, stepDurationS: 60, remainingS: 9.6, paused: false)?.text == "10 seconds.")
    }

    /// Silent on a step too short for the warning to be a warning, silent while paused (the clock
    /// is not moving), and silent — WITHOUT consuming the step — when the tick lands late, because
    /// "10 seconds" with four left is a lie.
    @Test func stepEndingIsSilentOnShortStepsWhilePausedAndWhenLate() {
        var coach = LiveRunCoach(unit: .metric)
        #expect(coach.stepEnding(stepIndex: 0, stepDurationS: 20, remainingS: 10, paused: false) == nil)   // a stride
        #expect(coach.stepEnding(stepIndex: 1, stepDurationS: 90, remainingS: 10, paused: true) == nil)    // paused
        // Late past the grace window: nothing, and the step is NOT marked — a later, earlier-in-
        // the-window tick cannot happen (time runs forward), so the step simply goes unwarned.
        #expect(coach.stepEnding(stepIndex: 2, stepDurationS: 90, remainingS: 5, paused: false) == nil)
        #expect(coach.stepEnding(stepIndex: 2, stepDurationS: 90, remainingS: 4, paused: false) == nil)
        // Inside the grace window (a tick that slipped a second or two) still speaks.
        #expect(coach.stepEnding(stepIndex: 3, stepDurationS: 90, remainingS: 7.5, paused: false)?.text == "10 seconds.")
        #expect(coach.stepEnding(stepIndex: 4, stepDurationS: 90, remainingS: 7.0, paused: false) == nil)
    }

    /// A warning is only true at its moment, so it is a TRANSITION: it pre-empts the spacing
    /// window instead of parking behind a nudge and firing with four seconds left.
    @Test func stepEndingPreEmptsTheSpacingWindow() {
        var coach = LiveRunCoach(unit: .metric)
        var gate = CoachCueGate()
        #expect(gate.admit(.init(text: "Pick it up.", priority: .ambient, kind: .nudge), at: 100) == .deliver)
        let warning = coach.stepEnding(stepIndex: 1, stepDurationS: 90, remainingS: 10, paused: false)!
        #expect(warning.priority == .transition)
        #expect(gate.admit(warning, at: 105) == .deliver)   // 5 s after the nudge: spoken anyway
    }

    @Test func stepEndingText() {
        #expect(CoachingCueBuilder.stepEnding(seconds: 10) == "10 seconds.")
        #expect(CoachingCueBuilder.stepEnding(seconds: 0).isEmpty)
    }

    // MARK: The zone on a split

    /// The zone trails the split as its own sentence, only when given and only when it is a zone.
    @Test func splitCarriesTheZoneOnlyWhenAsked() {
        #expect(CoachingCueBuilder.milestone(unitCount: 3, splitSecPerUnit: 525, unit: .imperial, zone: 2)
                == "Mile 3. 8:45 per mile. Zone 2.")
        #expect(CoachingCueBuilder.milestone(unitCount: 3, splitSecPerUnit: 525, unit: .imperial)
                == "Mile 3. 8:45 per mile.")
        #expect(CoachingCueBuilder.milestone(unitCount: 3, splitSecPerUnit: 525, unit: .imperial, zone: nil)
                == "Mile 3. 8:45 per mile.")
        // Out-of-range is not a zone.
        #expect(CoachingCueBuilder.milestone(unitCount: 3, splitSecPerUnit: 525, unit: .imperial, zone: 0)
                == "Mile 3. 8:45 per mile.")
        #expect(CoachingCueBuilder.milestone(unitCount: 3, splitSecPerUnit: 525, unit: .imperial, zone: 6)
                == "Mile 3. 8:45 per mile.")
        // No split figure still gets the zone; a ride gets it after the speed.
        #expect(CoachingCueBuilder.milestone(unitCount: 1, splitSecPerUnit: 0, unit: .metric, zone: 4)
                == "Kilometer 1. Zone 4.")
        #expect(CoachingCueBuilder.milestone(unitCount: 10, splitSecPerUnit: 240, unit: .metric, speech: .ride, zone: 3)
                == "Kilometer 10. 15 kilometers per hour. Zone 3.")
    }

    /// The run coach threads the zone it is handed into the split — and only the split. The
    /// caller (the view model) owns WHETHER to hand one over, from the dial and a live monitor.
    @Test func plannedFixThreadsTheZoneIntoTheSplit() {
        var withZone = LiveRunCoach(unit: .imperial)
        let lines = withZone.plannedFix(distanceM: Formatters.metersPerMile + 1, elapsedS: 525,
                                        smoothedPaceSPerKm: 326, paused: false, gpsLost: false, zone: 3)
        #expect(lines.map(\.text) == ["Mile 1. 8:45 per mile. Zone 3."])
        #expect(lines.first?.kind == .split)

        var without = LiveRunCoach(unit: .imperial)
        let plain = without.plannedFix(distanceM: Formatters.metersPerMile + 1, elapsedS: 525,
                                       smoothedPaceSPerKm: 326, paused: false, gpsLost: false)
        #expect(plain.map(\.text) == ["Mile 1. 8:45 per mile."])
    }

    /// The new fixed lines obey the house rules with the old ones: short, and no medical claims.
    @Test func newCuesAreConciseAndClaimFree() {
        let cues = [CoachingCueBuilder.stepEnding(seconds: 10), CoachingCueBuilder.zoneWord(2)]
        for cue in cues {
            #expect(!cue.isEmpty)
            #expect(cue.split(separator: " ").count <= 8)
            for term in ["injur", "pain", "diagnos", "medical"] { #expect(!cue.lowercased().contains(term)) }
        }
    }
}
