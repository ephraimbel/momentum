import Testing
import Foundation
@testable import Momentum

/// Structured guided-run expansion + live tracking (running-excellence R1). Pure and deterministic —
/// a prescribed session becomes an ordered step list the recorder guides you through.
struct StructuredWorkoutTests {

    // MARK: Parsing

    @Test func parsesIntervalStrings() {
        let a = StructuredWorkoutBuilder.parseIntervals("6×400m @ 5K pace")
        #expect(a?.reps == 6 && a?.distanceM == 400)
        let b = StructuredWorkoutBuilder.parseIntervals("5×800m @ 5K pace")
        #expect(b?.reps == 5 && b?.distanceM == 800)
        // Accepts a plain 'x' separator too.
        #expect(StructuredWorkoutBuilder.parseIntervals("10x200m")?.reps == 10)
        #expect(StructuredWorkoutBuilder.parseIntervals(nil) == nil)
        #expect(StructuredWorkoutBuilder.parseIntervals("Run/walk 1:1") == nil)
    }

    @Test func parsesRunWalkRatio() {
        let a = StructuredWorkoutBuilder.parseRunWalk("Run/walk 1:1")
        #expect(a?.runS == 60 && a?.walkS == 60)
        let b = StructuredWorkoutBuilder.parseRunWalk("Run/walk 2:1")
        #expect(b?.runS == 120 && b?.walkS == 60)
        #expect(StructuredWorkoutBuilder.parseRunWalk("6×400m") == nil)
    }

    // MARK: Interval expansion

    @Test func intervalsExpandToWarmupRepsRecoveriesCooldown() {
        let w = StructuredWorkoutBuilder.intervals(reps: 6, repDistanceM: 400, intervalPaceSPerKm: 300)
        // warm-up + 6 reps + 5 recoveries + cool-down = 13 steps.
        #expect(w.steps.count == 13)
        #expect(w.workStepCount == 6)
        #expect(w.steps.first?.kind == .warmup)
        #expect(w.steps.last?.kind == .cooldown)

        let reps = w.steps.filter { $0.kind == .work }
        #expect(reps.allSatisfy { $0.paceSPerKm == 300 })              // interval pace = P5k
        #expect(reps.first?.repIndex == 1 && reps.first?.repTotal == 6)
        #expect(reps.last?.repIndex == 6)

        // Recovery jogs are timed and run at the recovery offset (+110 vs P5k).
        let rec = w.steps.first { $0.kind == .recovery }
        #expect(rec?.target == .duration(90))
        #expect(rec?.paceSPerKm == 410)
        // Warm-up/cool-down are easy (+80).
        #expect(w.steps.first?.paceSPerKm == 380)
    }

    @Test func longerRepsGetLongerRecoveries() {
        let w = StructuredWorkoutBuilder.intervals(reps: 5, repDistanceM: 800, intervalPaceSPerKm: 300)
        let rec = w.steps.first { $0.kind == .recovery }
        #expect(rec?.target == .duration(120))
    }

    // MARK: Tempo expansion

    @Test func tempoPreservesTotalDistance() {
        let w = StructuredWorkoutBuilder.tempo(totalDistanceM: 5000, tempoPaceSPerKm: 320)
        #expect(w?.steps.count == 3)
        #expect(w?.steps[1].kind == .work && w?.steps[1].paceSPerKm == 320)
        // 1 km warm-up + 3 km block + 1 km cool-down = the prescribed 5 km.
        #expect(w?.plannedDistanceM == 5000)
        #expect(StructuredWorkoutBuilder.tempo(totalDistanceM: 0, tempoPaceSPerKm: 320) == nil)
    }

    // MARK: build(from:)

    @Test func buildsIntervalSessionAndSkipsPlainRuns() {
        let interval = PlannedSession()
        interval.discipline = .running
        interval.runType = .intervals
        interval.targetPaceSPerKm = 300
        interval.intervals = "6×400m @ 5K pace"
        #expect(StructuredWorkoutBuilder.build(from: interval)?.workStepCount == 6)

        let easy = PlannedSession()
        easy.discipline = .running
        easy.runType = .easy
        easy.targetPaceSPerKm = 380
        #expect(StructuredWorkoutBuilder.build(from: easy) == nil)   // a plain easy run needs no guidance
    }

    // MARK: Live tracker

    @Test func trackerAdvancesThroughStepsAndReAnchors() {
        let w = StructuredWorkoutBuilder.intervals(reps: 2, repDistanceM: 400, intervalPaceSPerKm: 300)
        var t = StructuredRunTracker(steps: w.steps)   // warm-up, rep1, recovery, rep2, cool-down
        #expect(t.current?.kind == .warmup)
        #expect(t.remaining(distanceM: 0, elapsedS: 0) == 1000)

        // Finish the 1 km warm-up.
        var changed = t.advance(distanceM: 1000, elapsedS: 300)
        #expect(changed)
        #expect(t.current?.kind == .work && t.current?.repIndex == 1)
        #expect(t.remaining(distanceM: 1000, elapsedS: 300) == 400)   // fresh rep, re-anchored

        // Finish rep 1 → timed recovery.
        changed = t.advance(distanceM: 1400, elapsedS: 400)
        #expect(changed)
        #expect(t.current?.kind == .recovery)
        #expect(t.remaining(distanceM: 1400, elapsedS: 400) == 90)    // duration measured from here

        // Standing recovery: distance flat, time elapses.
        changed = t.advance(distanceM: 1400, elapsedS: 490)
        #expect(changed)
        #expect(t.current?.kind == .work && t.current?.repIndex == 2)
    }

    @Test func trackerAdherenceRespectsBand() {
        let w = StructuredWorkoutBuilder.intervals(reps: 1, repDistanceM: 400, intervalPaceSPerKm: 300)
        var t = StructuredRunTracker(steps: w.steps)
        t.advance(distanceM: 1000, elapsedS: 300)          // into the rep (target 300 ±12)
        #expect(t.adherence(currentPaceSPerKm: 300) == .onPace)
        #expect(t.adherence(currentPaceSPerKm: 250) == .tooFast)   // faster = lower s/km
        #expect(t.adherence(currentPaceSPerKm: 330) == .tooSlow)
        #expect(t.adherence(currentPaceSPerKm: 0) == .noTarget)
    }

    @Test func trackerSkipAndCompletion() {
        let w = StructuredWorkoutBuilder.intervals(reps: 1, repDistanceM: 400, intervalPaceSPerKm: 300)
        var t = StructuredRunTracker(steps: w.steps)       // warm-up, rep1, cool-down
        let skippedWarmup = t.skip(distanceM: 200, elapsedS: 60)
        #expect(skippedWarmup)
        #expect(t.current?.kind == .work)
        t.skip(distanceM: 600, elapsedS: 120)              // skip rep
        t.skip(distanceM: 1000, elapsedS: 240)             // skip cool-down
        #expect(t.isComplete)
        #expect(t.current == nil)
        let skipWhenDone = t.skip(distanceM: 1000, elapsedS: 240)
        #expect(!skipWhenDone)                             // no-op once complete
    }
}

/// The structured-workout spoken cues (extends CoachingCueBuilder) — natural, no-shame, claim-free.
struct StructuredCueTests {

    @Test func stepStartSpeaksRepsRecoveriesAndBookends() {
        let warmup = WorkoutStep(kind: .warmup, target: .distance(1000), paceSPerKm: 380)
        #expect(CoachingCueBuilder.stepStart(warmup) == "Warm up. Ease in.")

        let rep = WorkoutStep(kind: .work, target: .distance(400), paceSPerKm: 300, repIndex: 3, repTotal: 6)
        #expect(CoachingCueBuilder.stepStart(rep) == "Rep 3 of 6. 400 meters at your target. Go.")

        let recovery = WorkoutStep(kind: .recovery, target: .duration(90), paceSPerKm: 410)
        #expect(CoachingCueBuilder.stepStart(recovery) == "Recover. 1 minute 30 seconds easy.")
    }

    @Test func spokenTargetReadsDistanceAndDuration() {
        #expect(CoachingCueBuilder.spokenTarget(.distance(400)) == "400 meters")
        #expect(CoachingCueBuilder.spokenTarget(.distance(1000)) == "1 kilometer")
        #expect(CoachingCueBuilder.spokenTarget(.distance(2000)) == "2 kilometers")
        #expect(CoachingCueBuilder.spokenTarget(.duration(90)) == "1 minute 30 seconds")
    }

    @Test func paceNudgeAndCompletionAreShortAndClaimFree() {
        #expect(CoachingCueBuilder.paceNudge(.tooFast) == "Ease back a touch.")
        #expect(CoachingCueBuilder.paceNudge(.tooSlow) == "Pick it up.")
        #expect(CoachingCueBuilder.paceNudge(.onPace).isEmpty)
        let banned = ["injur", "pain", "medical", "fail"]
        for cue in [CoachingCueBuilder.workoutComplete(), CoachingCueBuilder.paceNudge(.tooFast)] {
            for term in banned { #expect(!cue.lowercased().contains(term)) }
        }
    }
}
