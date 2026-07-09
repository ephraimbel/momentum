import Testing
import Foundation
@testable import Momentum

/// Structured guided-run expansion + live tracking (running-excellence R1). Pure and deterministic —
/// a prescribed session becomes an ordered step list the recorder guides you through.
struct StructuredWorkoutTests {

    /// Distance intervals with easy/recovery derived from the rep pace (P5k) — for the tracker tests.
    private func iv(_ reps: Int, _ distM: Double, pace: Double) -> StructuredWorkout {
        StructuredWorkoutBuilder.intervals(reps: reps, repTarget: .distance(distM), repPace: pace,
                                           easyPace: pace + 80, recoveryPace: pace + 110,
                                           unitLabel: distM < 1000 ? "\(Int(distM))m" : "\(Int(distM / 1000))km")
    }

    // MARK: Parsing

    @Test func parsesIntervalStrings() {
        let a = StructuredWorkoutBuilder.parseIntervals("6×400m @ 5K pace")
        #expect(a?.reps == 6 && a?.distanceM == 400)
        let b = StructuredWorkoutBuilder.parseIntervals("5×800m @ 5K pace")
        #expect(b?.reps == 5 && b?.distanceM == 800)
        // Accepts a plain 'x' separator too.
        #expect(StructuredWorkoutBuilder.parseIntervals("10x200m")?.reps == 10)
        // Unit-aware: a km/k suffix scales to meters (regression: "1km" must be 1000 m, not 1 m).
        #expect(StructuredWorkoutBuilder.parseIntervals("4×1km")?.distanceM == 1000)
        #expect(StructuredWorkoutBuilder.parseIntervals("3×1.5km @ threshold")?.distanceM == 1500)
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
        let w = iv(6, 400, pace: 300)
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
        let w = iv(5, 800, pace: 300)
        let rec = w.steps.first { $0.kind == .recovery }
        #expect(rec?.target == .duration(120))
    }

    // MARK: Tempo expansion

    @Test func tempoPreservesTotalDistance() {
        let w = StructuredWorkoutBuilder.tempo(totalDistanceM: 5000, tempoPaceSPerKm: 320, easyPace: 380)
        #expect(w?.steps.count == 3)
        #expect(w?.steps[1].kind == .work && w?.steps[1].paceSPerKm == 320)
        // 1 km warm-up + 3 km block + 1 km cool-down = the prescribed 5 km.
        #expect(w?.plannedDistanceM == 5000)
        #expect(StructuredWorkoutBuilder.tempo(totalDistanceM: 0, tempoPaceSPerKm: 320, easyPace: 380) == nil)
    }

    // MARK: Workout variety

    @Test func parsesTimeAndSpecialtyFormats() {
        #expect(StructuredWorkoutBuilder.parseTimeReps("5×3min @ VO2")?.seconds == 180)
        #expect(StructuredWorkoutBuilder.parseIntervals("5×3min @ VO2") == nil)   // time rejected as distance
        #expect(StructuredWorkoutBuilder.parseTimedReps("8×45sec hills", keyword: "hill")?.reps == 8)
        #expect(StructuredWorkoutBuilder.parseTimedReps("6×20sec strides", keyword: "stride")?.seconds == 20)
        let f = StructuredWorkoutBuilder.parseFartlek("8×(1min hard / 1min float)")
        #expect(f?.reps == 8 && f?.onS == 60 && f?.floatS == 60)
    }

    private func session(_ rt: RunType, pace: Double, iv: String?, dist: Double? = 8000) -> PlannedSession {
        let s = PlannedSession(); s.discipline = .running; s.runType = rt
        s.targetPaceSPerKm = pace; s.intervals = iv; s.targetDistanceM = dist
        return s
    }

    @Test func buildsEachVarietyType() {
        // VO₂ intervals: rep pace = the session's (faster than easy); recovery derives from P5k (300),
        // NOT the rep pace — the whole point of passing p5kSPerKm.
        let vo2 = StructuredWorkoutBuilder.build(from: session(.intervals, pace: 294, iv: "5×3min @ VO2"), p5kSPerKm: 300)
        #expect(vo2?.workStepCount == 5)
        #expect(vo2?.steps.first { $0.kind == .work }?.paceSPerKm == 294)
        #expect(vo2?.steps.first { $0.kind == .recovery }?.paceSPerKm == 410)   // 300 + 110

        let hills = StructuredWorkoutBuilder.build(from: session(.hills, pace: 380, iv: "8×45sec hills"), p5kSPerKm: 300)
        #expect(hills?.workStepCount == 8)
        #expect(hills?.steps.first { $0.kind == .work }?.title == "Hill")
        #expect(hills?.steps.first { $0.kind == .work }?.paceSPerKm == nil)     // effort-based

        let fartlek = StructuredWorkoutBuilder.build(from: session(.fartlek, pace: 380, iv: "8×(1min hard / 1min float)"), p5kSPerKm: 300)
        #expect(fartlek?.workStepCount == 8)
        #expect(fartlek?.steps.first { $0.kind == .work }?.title == "Surge")

        let strides = StructuredWorkoutBuilder.build(from: session(.strides, pace: 380, iv: "6×20sec strides"), p5kSPerKm: 300)
        #expect(strides?.workStepCount == 6)

        let prog = StructuredWorkoutBuilder.build(from: session(.progression, pace: 390, iv: nil, dist: 9000), p5kSPerKm: 300)
        #expect(prog?.steps.count == 3)                       // easy → moderate → strong thirds
        #expect(prog?.steps.last?.paceSPerKm == 315)          // strong = P5k + 15
    }

    // MARK: Per-rep capture (post-run breakdown)

    @Test func trackerCapturesRepResultsWithVerdict() {
        let w = iv(2, 400, pace: 300)   // warm-up, rep1(400@300), recovery(90s), rep2(400@300), cool-down
        var t = StructuredRunTracker(steps: w.steps)
        t.advance(distanceM: 1000, elapsedS: 300)          // finish warm-up → into rep 1
        t.advance(distanceM: 1400, elapsedS: 400)          // rep 1: 400 m in 100 s = 250 s/km (fast)
        #expect(t.completedReps.count == 1)
        let r1 = t.completedReps[0]
        #expect(abs(r1.achievedPaceSPerKm - 250) < 1)
        #expect(r1.targetPaceSPerKm == 300 && r1.repIndex == 1 && r1.repTotal == 2)
        #expect(r1.verdict == .tooFast)                    // 250 < 300 − 12

        t.advance(distanceM: 1400, elapsedS: 490)          // recovery (90 s) — NOT a rep
        t.advance(distanceM: 1800, elapsedS: 610)          // rep 2: 400 m in 120 s = 300 s/km (on pace)
        #expect(t.completedReps.count == 2)                // recovery added nothing
        #expect(t.completedReps[1].verdict == .onPace)
    }

    @Test func repResultVerdictAndLabel() {
        let fast = RepResult(repIndex: 3, repTotal: 6, title: nil, targetPaceSPerKm: 300,
                             achievedPaceSPerKm: 280, distanceM: 400, durationS: 112)
        #expect(fast.verdict == .tooFast && fast.label == "Rep 3/6")
        let hill = RepResult(repIndex: 2, repTotal: 8, title: "Hill", targetPaceSPerKm: nil,
                             achievedPaceSPerKm: 320, distanceM: 0, durationS: 45)
        #expect(hill.verdict == .noTarget && hill.label == "Hill 2/8")   // effort reps have no pace target
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
        let w = iv(2, 400, pace: 300)
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
        let w = iv(1, 400, pace: 300)
        var t = StructuredRunTracker(steps: w.steps)
        t.advance(distanceM: 1000, elapsedS: 300)          // into the rep (target 300 ±12)
        #expect(t.adherence(currentPaceSPerKm: 300) == .onPace)
        #expect(t.adherence(currentPaceSPerKm: 250) == .tooFast)   // faster = lower s/km
        #expect(t.adherence(currentPaceSPerKm: 330) == .tooSlow)
        #expect(t.adherence(currentPaceSPerKm: 0) == .noTarget)
    }

    @Test func trackerSkipAndCompletion() {
        let w = iv(1, 400, pace: 300)
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
