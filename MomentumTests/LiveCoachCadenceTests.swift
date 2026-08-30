import Testing
import Foundation
@testable import Momentum

/// Replays whole runs through the pure live coach (`LiveRunCoach` + `CoachCueGate`) one second at a
/// time and pins the EXACT sequence and spacing of what the athlete hears. The view model routes
/// these same lines to the screen and the voice, so this is the coach's cadence contract:
/// - never two cues inside the spacing window (transitions excepted, they pre-empt)
/// - nothing while paused, and nothing parked dumps on resume
/// - a nudge only after the drift has HELD, then a long cooldown; never right after a transition
/// - the goal line carries its moment (no split talked over it); halfway / last-unit arithmetic
struct LiveCoachCadenceTests {

    /// The view model's wall-clock tasks, modelled on the simulated clock.
    private struct Harness {
        var coach: LiveRunCoach
        var gate = CoachCueGate()
        var log: [(t: TimeInterval, line: CoachCueGate.Line)] = []
        private var parkedFireAt: TimeInterval?

        init(coach: LiveRunCoach) { self.coach = coach }

        mutating func say(_ line: CoachCueGate.Line, stepIndex: Int? = nil, at t: TimeInterval) {
            switch gate.admit(line, at: t) {
            case .deliver:
                parkedFireAt = nil
                log.append((t, line))
                coach.spoke(line, stepIndex: stepIndex, at: t)
            case let .park(delayS):
                parkedFireAt = t + delayS
            case .drop:
                break
            }
        }

        /// The parked-cue task waking up (the view model sleeps `delayS` then takes the pending line).
        mutating func tick(_ t: TimeInterval, paused: Bool) {
            guard let fire = parkedFireAt, t >= fire else { return }
            parkedFireAt = nil
            guard !paused, let p = gate.takePending(at: fire) else { return }
            log.append((fire, p))
            coach.spoke(p, stepIndex: nil, at: fire)
        }

        mutating func pause() { parkedFireAt = nil; gate.clearPending() }

        var texts: [String] { log.map(\.line.text) }

        /// No two delivered lines inside the spacing window unless the later one is a transition.
        var spacingHolds: Bool {
            zip(log, log.dropFirst()).allSatisfy { a, b in
                b.line.priority == .transition || b.t - a.t >= CoachCueGate.spacingS
            }
        }
    }

    private let mile = Formatters.metersPerMile

    /// A planned 14-mile long run at 360 s/km (~9:39 /mi), with a short surge in mile 2, a slow
    /// patch and a second surge in mile 4, and a pause in mile 9. Second-by-second fixes.
    @Test func fourteenMilePlannedRunSaysExactlyThis() {
        let goal = 14 * mile, target = 360.0
        var h = Harness(coach: LiveRunCoach(unit: .imperial, goalMeters: goal, targetPaceSPerKm: target))
        h.say(h.coach.plannedIntro()!, at: 0)

        func pace(at t: TimeInterval) -> Double {
            switch t {
            case 700..<760: 320            // surge: 40 s/km fast (past the 25 s outer band)
            case 1800..<1900: 400          // slow patch
            case 1900..<1950: 320          // second surge, inside the 120 s cooldown at first
            default: target
            }
        }
        var d = 0.0
        var paused = false
        var pauseTicks = 0
        var t = 0.0
        while d < 15.2 * mile {
            t += 1
            // Mile 9: a 45 s pause. Moving time freezes, distance holds, fixes report paused.
            if d >= 9 * mile, pauseTicks < 45 {
                paused = true; pauseTicks += 1
                h.pause()
                let lines = h.coach.plannedFix(distanceM: d, elapsedS: t - Double(pauseTicks),
                                               smoothedPaceSPerKm: 0, paused: true, gpsLost: false)
                #expect(lines.isEmpty, "nothing is said while paused")
                continue
            }
            if paused { paused = false }
            let e = t - Double(pauseTicks)   // moving time
            let p = pace(at: e)
            d += 1000 / p
            for line in h.coach.plannedFix(distanceM: d, elapsedS: e, smoothedPaceSPerKm: p,
                                           paused: false, gpsLost: false) {
                h.say(line, at: e)
            }
            h.tick(e, paused: false)
        }

        #expect(h.spacingHolds)
        let texts = h.texts
        #expect(texts.first == "14 miles today. Hold about 9:40 per mile.")

        // Splits: every mile is called with its clock split, no "0:00", no minutes-and-seconds prose.
        let splits = h.log.filter { $0.line.kind == .split }
        #expect(splits.count == 14)   // miles 1–13 and 15; mile 14 is the goal line's moment
        #expect(splits.allSatisfy { $0.line.text.range(of: #"^Mile \d+\. \d+:\d\d per mile\.$"#, options: .regularExpression) != nil })
        #expect(!texts.contains { $0.contains("0:00") || $0.contains("minutes") })
        #expect(texts.contains("Mile 1. 9:40 per mile."))   // 580 ticks of 1000/360 m
        #expect(!texts.contains { $0.hasPrefix("Mile 14.") })

        // Drift: the surge in mile 2 holds 8 s before the coach says a word, then a 120 s cooldown
        // swallows the second surge until it has held past the cooldown.
        let nudges = h.log.filter { $0.line.kind == .nudge }
        #expect(nudges.map(\.line.text) == ["A touch quick for today. Ease back to your target.",
                                            "Under your target. Pick it up a little.",
                                            "A touch quick for today. Ease back to your target."])
        #expect(nudges.map(\.t) == [708, 1808, 1929])
        // Planned runs never hear "On pace": silence is the norm.
        #expect(!h.log.contains { $0.line.kind == .encouragement })

        // Halfway rides 12 s behind the mile-7 split (same fix), and says what is left.
        let mile7 = h.log.first { $0.line.text.hasPrefix("Mile 7.") }!
        let halfway = h.log.first { $0.line.kind == .halfway }!
        #expect(halfway.line.text == "Halfway. 7 miles to go.")
        #expect(halfway.t == mile7.t + CoachCueGate.spacingS)
        // Last mile rides behind the mile-13 split the same way.
        let mile13 = h.log.first { $0.line.text.hasPrefix("Mile 13.") }!
        let last = h.log.first { $0.line.kind == .finalStretch }!
        #expect(last.line.text == "Last mile.")
        #expect(last.t == mile13.t + CoachCueGate.spacingS)
        // The goal is one line, in the same breath as the 14th mile would have been.
        let goalLine = h.log.first { $0.line.kind == .goal }!
        #expect(goalLine.line.text == "Goal reached. Everything from here is extra.")
        #expect(h.log.filter { $0.line.kind == .goal }.count == 1)
        #expect(h.log.last?.line.text.range(of: #"^Mile 15\. 9:(39|40) per mile\.$"#, options: .regularExpression) != nil)

        // The full order, kinds only.
        let kinds = h.log.map(\.line.kind)
        #expect(kinds == [.intro, .split, .nudge, .split, .split, .nudge, .nudge, .split, .split, .split,
                          .split, .halfway, .split, .split, .split, .split, .split, .split, .finalStretch,
                          .goal, .split])
    }

    @Test func halfwayAndLastUnitArithmetic() {
        func run(goal: Double, unit: DistanceUnit, pace: Double = 350) -> [String] {
            var h = Harness(coach: LiveRunCoach(unit: unit, goalMeters: goal, targetPaceSPerKm: nil))
            h.say(h.coach.plannedIntro()!, at: 0)
            var d = 0.0, t = 0.0
            while d < goal + 30 {
                t += 1; d += 1000 / pace
                for l in h.coach.plannedFix(distanceM: d, elapsedS: t, smoothedPaceSPerKm: pace,
                                            paused: false, gpsLost: false) { h.say(l, at: t) }
                h.tick(t, paused: false)
            }
            #expect(h.spacingHolds)
            return h.texts.filter { !$0.hasPrefix("Mile") && !$0.hasPrefix("Kilometer") }
        }
        #expect(run(goal: 5 * mile, unit: .imperial) == ["5 miles today.", "Halfway. 2.5 miles to go.", "Last mile.",
                                                         "Goal reached. Everything from here is extra."])
        #expect(run(goal: 14 * mile, unit: .imperial) == ["14 miles today.", "Halfway. 7 miles to go.", "Last mile.",
                                                          "Goal reached. Everything from here is extra."])
        #expect(run(goal: 21_100, unit: .metric) == ["21.1 kilometers today.", "Halfway. 10.5 kilometers to go.",
                                                     "Last kilometer.", "Goal reached. Everything from here is extra."])
        #expect(run(goal: 50_000, unit: .metric) == ["50 kilometers today.", "Halfway. 25 kilometers to go.",
                                                     "Last kilometer.", "Goal reached. Everything from here is extra."])
        // Half marathon in miles: 13.1, halfway at 6.55.
        #expect(run(goal: 21_100, unit: .imperial) == ["13.1 miles today.", "Halfway. 6.6 miles to go.", "Last mile.",
                                                       "Goal reached. Everything from here is extra."])
        // Too short for "last mile" (under 3 units) — halfway only; under 2 units, the goal alone.
        #expect(run(goal: 2 * mile, unit: .imperial) == ["2 miles today.", "Halfway. 1 mile to go.",
                                                         "Goal reached. Everything from here is extra."])
        #expect(run(goal: 1.5 * mile, unit: .imperial) == ["1.5 miles today.", "Goal reached. Everything from here is extra."])
    }

    @Test func freeRunIsSilentExceptForSplitsAndARideCallsSpeed() {
        var h = Harness(coach: LiveRunCoach(unit: .metric, goalMeters: nil, targetPaceSPerKm: nil))
        #expect(h.coach.plannedIntro() == nil)
        var d = 0.0, t = 0.0
        while d < 3100 {
            t += 1; d += 4   // 250 s/km, an exact 4 m per tick
            for l in h.coach.plannedFix(distanceM: d, elapsedS: t, smoothedPaceSPerKm: 250,   // no target to drift from
                                        paused: false, gpsLost: false) { h.say(l, at: t) }
        }
        #expect(h.texts == ["Kilometer 1. 4:10 per kilometer.", "Kilometer 2. 4:10 per kilometer.",
                            "Kilometer 3. 4:10 per kilometer."])

        // A ride calls the same mile in the rider's instrument: speed, not pace. 8 m/s is 17.9 mph.
        var ride = Harness(coach: LiveRunCoach(unit: .imperial, goalMeters: nil, targetPaceSPerKm: nil,
                                               speech: .ride))
        d = 0; t = 0
        while d < 2.1 * mile {
            t += 1; d += 8
            for l in ride.coach.plannedFix(distanceM: d, elapsedS: t, smoothedPaceSPerKm: 125,
                                           paused: false, gpsLost: false) { ride.say(l, at: t) }
        }
        #expect(ride.texts == ["Mile 1. 17.8 miles per hour.", "Mile 2. 17.9 miles per hour."])
    }

    @Test func aParkedMilestoneIsVoidedByAPauseAndNeverDumpsOnResume() {
        var h = Harness(coach: LiveRunCoach(unit: .imperial, goalMeters: 4 * mile, targetPaceSPerKm: nil))
        h.say(h.coach.plannedIntro()!, at: 0)
        var d = 0.0, t = 0.0
        var pausedOnce = false
        while d < 2.5 * mile {
            t += 1; d += 1000 / 360
            let lines = h.coach.plannedFix(distanceM: d, elapsedS: t, smoothedPaceSPerKm: 360,
                                           paused: false, gpsLost: false)
            for l in lines { h.say(l, at: t) }
            // The mile-2 fix also crosses halfway: the split is spoken, halfway parks. Pause now.
            if !pausedOnce, lines.contains(where: { $0.kind == .halfway }) {
                pausedOnce = true
                h.pause()
                for _ in 0..<30 {
                    #expect(h.coach.plannedFix(distanceM: d, elapsedS: t, smoothedPaceSPerKm: 0,
                                               paused: true, gpsLost: false).isEmpty)
                }
            }
            h.tick(t, paused: false)
        }
        #expect(pausedOnce)
        #expect(h.texts == ["4 miles today.", "Mile 1. 9:40 per mile.", "Mile 2. 9:39 per mile."])
    }

    @Test func plannedDriftWaitsOutTheWarmUpAndTheHoldAndGPSLoss() {
        var h = Harness(coach: LiveRunCoach(unit: .metric, goalMeters: 8000, targetPaceSPerKm: 360))
        var d = 0.0, t = 0.0
        // 20 s/km off: inside the outer band → never a word. Then 30 off from 100 s (still in the
        // warm-up hold) → nothing until 180 s + 8 s hold.
        while t < 260 {
            t += 1
            let p = t < 100 ? 380.0 : 390.0
            d += 1000 / p
            for l in h.coach.plannedFix(distanceM: d, elapsedS: t, smoothedPaceSPerKm: p,
                                        paused: false, gpsLost: t >= 200 && t < 230) { h.say(l, at: t) }
        }
        // Drift first counted at 181 s, held 8 s → 189 s. But GPS is lost 200–230, which is after the
        // first word; the nudge lands at 189 exactly once.
        let nudges = h.log.filter { $0.line.kind == .nudge }
        #expect(nudges.map(\.t) == [189])
        #expect(nudges.first?.line.text == "Under your target. Pick it up a little.")
    }

    /// A guided 4×400 m session, simulated the way the view model drives it: a 1 Hz tick advances
    /// the tracker; a step change is a transition line, otherwise the in-step word is asked for.
    @Test func structuredSessionSaysExactlyThis() {
        let w = StructuredWorkoutBuilder.intervals(reps: 4, repTarget: .distance(400), repPace: 300,
                                                   easyPace: 380, recoveryPace: 410, unitLabel: "400m")
        var tracker = StructuredRunTracker(steps: w.steps)
        var h = Harness(coach: LiveRunCoach(unit: .metric))
        // arm(): the intro leads, the first step is called 5 s later.
        h.say(.init(text: CoachingCueBuilder.workoutIntro(w), priority: .transition, kind: .intro), at: 0)
        var introTailDue: TimeInterval? = 5

        /// Running pace per step: rep 2 too slow, rep 3 too fast, the rest on target. Recoveries jog.
        func pace(_ step: WorkoutStep) -> Double {
            switch (step.kind, step.repIndex) {
            case (.work, 2): 340
            case (.work, 3): 260
            case (.work, _): 300
            case (.recovery, _): 500
            default: 380
            }
        }
        var d = 0.0, t = 0.0
        var stepStarts: [(t: TimeInterval, index: Int)] = []
        while !tracker.isComplete {
            t += 1
            guard let step = tracker.current else { break }
            d += 1000 / pace(step)
            if let due = introTailDue, t >= due {
                introTailDue = nil
                if tracker.index == 0 {
                    h.say(.init(text: CoachingCueBuilder.stepStart(step), priority: .transition, kind: .stepStart), at: t)
                    stepStarts.append((t, 0))
                }
            }
            if tracker.advance(distanceM: d, elapsedS: t) {
                h.coach.stepChanged()
                introTailDue = nil
                if tracker.isComplete {
                    h.say(.init(text: CoachingCueBuilder.workoutComplete(), priority: .transition, kind: .complete), at: t)
                } else if let next = tracker.current {
                    h.say(.init(text: CoachingCueBuilder.stepStart(next), priority: .transition, kind: .stepStart), at: t)
                    stepStarts.append((t, tracker.index))
                }
                continue
            }
            let adherence = tracker.adherence(currentPaceSPerKm: pace(step))
            if let line = h.coach.structuredTick(stepIndex: tracker.index, stepAnchorElapsedS: tracker.anchorElapsedS,
                                                 adherence: adherence, elapsedS: t, paused: false) {
                h.say(line, stepIndex: tracker.index, at: t)
            }
        }

        #expect(h.spacingHolds)
        #expect(h.texts == [
            "Today: 4 repeats of 400 meters. Warm-up first. I'll call every step.",
            "Warm up. Ease in.",
            "Rep 1 of 4. 400 meters at your target. Go.",
            "On pace.",
            "Recover. 1 minute 30 seconds easy.",
            "Rep 2 of 4. 400 meters at your target. Go.",
            "Pick it up.",
            "Pick it up.",             // a 136 s rep run slow throughout: once more after the 90 s cooldown
            "Recover. 1 minute 30 seconds easy.",
            "Rep 3 of 4. 400 meters at your target. Go.",
            "Ease back a touch.",
            "Recover. 1 minute 30 seconds easy.",
            "Rep 4 of 4. Last one. 400 meters at your target. Go.",
            "Right on target.",
            "Cool down. Nice and easy.",
            "Workout complete. That's the work done.",
        ])
        // Timing: the first step is called 5 s after the intro; "on pace" comes 31 s into a rep
        // (30 s settle + the next tick); a nudge 24 s in (15 s settle + 8 s hold + the next tick),
        // never on the heels of the step call; the second nudge in rep 2 waits out the cooldown.
        let byKind = { (k: CoachCueGate.Line.Kind) in h.log.filter { $0.line.kind == k } }
        #expect(byKind(.stepStart).first?.t == 5)
        let rep1 = stepStarts.first { $0.index == 1 }!.t
        #expect(byKind(.encouragement).first?.t == rep1 + LiveRunCoach.encouragementAfterS + 1)
        let rep2 = stepStarts.first { $0.index == 3 }!.t
        let firstNudge = rep2 + LiveRunCoach.stepSettleS + LiveRunCoach.driftHoldS + 1
        #expect(byKind(.nudge).map(\.t).prefix(2) == [firstNudge, firstNudge + LiveRunCoach.nudgeCooldownS + 1])
        #expect(byKind(.nudge).count == 3)
        let rep3 = stepStarts.first { $0.index == 5 }!.t
        #expect(byKind(.nudge).last?.t == rep3 + LiveRunCoach.stepSettleS + LiveRunCoach.driftHoldS + 1)
    }

    @Test func aNudgeDroppedBehindASplitDoesNotBurnItsCooldown() {
        var h = Harness(coach: LiveRunCoach(unit: .metric, goalMeters: nil, targetPaceSPerKm: 360))
        // Deep into the run, on target, just short of the km-3 boundary; the km-2 split is behind us.
        var d = 2995.0, t = 1076.0
        for l in h.coach.plannedFix(distanceM: d, elapsedS: t, smoothedPaceSPerKm: 360, paused: false, gpsLost: false) {
            h.say(l, at: t)   // "Kilometer 2." lands here (the coach's first sight of the run)
        }
        for _ in 0..<40 {
            t += 1; d += 1000 / 300   // 60 s/km fast from here: drift and the km-3 split arrive together
            for l in h.coach.plannedFix(distanceM: d, elapsedS: t, smoothedPaceSPerKm: 300, paused: false, gpsLost: false) {
                h.say(l, at: t)
            }
            h.tick(t, paused: false)
        }
        // Split parked behind the 1076 line → 1088. Drift counted from 1077, held 8 s → wants to
        // speak at 1085, dropped inside the window; and again behind the 1088 split; it returns at
        // 1100 instead of going quiet for two minutes.
        #expect(h.log.map(\.t) == [1076, 1088, 1100])
        #expect(h.log.last?.line.text == "A touch quick for today. Ease back to your target.")
        #expect(h.spacingHolds)
    }

    @Test func theGateItself() {
        var g = CoachCueGate()
        let split = CoachCueGate.Line(text: "Mile 1. 9:00 per mile.", priority: .milestone, kind: .split)
        let nudge = CoachCueGate.Line(text: "Pick it up.", priority: .ambient, kind: .nudge)
        let go = CoachCueGate.Line(text: "Rep 1 of 4. Go.", priority: .transition, kind: .stepStart)
        #expect(g.admit(split, at: 100) == .deliver)
        #expect(g.admit(nudge, at: 105) == .drop)                         // ambient inside the window: gone
        #expect(g.admit(split, at: 108) == .park(delayS: 4))              // milestone waits its turn
        #expect(g.pending == split)
        #expect(g.admit(nudge, at: 112) == .drop)                         // the window is open, but the split is owed first
        #expect(g.pending == split)
        #expect(g.admit(go, at: 109) == .deliver)                         // a transition pre-empts…
        #expect(g.pending == nil)                                         // …and voids what was parked
        #expect(g.admit(.init(text: "", priority: .transition), at: 110) == .drop)   // never an empty line
        #expect(g.admit(split, at: 121) == .deliver)                      // window measured from the transition
        _ = g.admit(split, at: 125)
        g.clearPending()
        #expect(g.takePending(at: 140) == nil)
    }
}
