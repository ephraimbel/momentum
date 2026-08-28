import Foundation

/// The SwiftData-facing half of the structured-workout builder: expand a `PlannedSession` into
/// the guided step list. Split from `StructuredWorkout.swift` (which stays pure Foundation and
/// ships to the watch target) because this entry point touches `PlannedSession`, `PlanEngine`,
/// and `DanielsPaces` — phone-only concerns.
extension StructuredWorkoutBuilder {

    /// Expand a planned session into a guided workout, or `nil` when it's a plain run that needs no
    /// in-run structure. `p5kSPerKm` (the athlete's calibrated 5k pace) lets warm-up / recovery / easy
    /// steps hold the right pace even when the *work* reps run faster or slower than 5k pace (VO₂ vs
    /// threshold reps); when omitted it's recovered from the session's own pace. `raceDistanceM` (the
    /// athlete's goal race) prices the race-pace finish block on quality long runs — omitted, a long
    /// race's marathon pace stands in. Pure + deterministic.
    static func build(from session: PlannedSession, p5kSPerKm: Double? = nil,
                      raceDistanceM: Double? = nil, goalRacePaceSPerKm: Double? = nil) -> StructuredWorkout? {
        guard session.discipline == .running,
              let runType = session.runType,
              let pace = session.targetPaceSPerKm, pace > 0 else { return nil }

        let p5k = p5kSPerKm ?? DanielsPaces.p5kSPerKm(fromPace: pace, type: runType)
        let easyPace = PlanEngine.pace(.easy, p5k: p5k)
        let recoveryPace = PlanEngine.pace(.recovery, p5k: p5k)
        let vo2Pace = PlanEngine.pace(.intervals, p5k: p5k)   // vVO₂max — surges / by-feel hard bits

        switch runType {
        case .intervals:
            // Distance reps ("6×400m", "4×1km") or time reps ("5×3min"); rep pace = the plan's target
            // (5k / VO₂ / threshold), recovery + warm-up derive from P5k. Threshold cruise reps take
            // a SHORT 60 s recovery (Daniels — the point of cruise intervals is that T effort barely
            // drops between reps); the default 120 s doubled the rest and diluted the stimulus.
            let cruise = session.intervals?.lowercased().contains("threshold") == true
            if let d = parseIntervals(session.intervals) {
                return intervals(reps: d.reps, repTarget: .distance(d.distanceM), repPace: pace,
                                 easyPace: easyPace, recoveryPace: recoveryPace, unitLabel: repDistanceLabel(d.distanceM),
                                 recoveryOverrideS: cruise ? 60 : nil)
            }
            if let t = parseTimeReps(session.intervals) {
                return intervals(reps: t.reps, repTarget: .duration(t.seconds), repPace: pace,
                                 easyPace: easyPace, recoveryPace: recoveryPace, unitLabel: minLabel(t.seconds))
            }
            return nil
        case .tempo:
            return tempo(totalDistanceM: session.targetDistanceM ?? 0, tempoPaceSPerKm: pace, easyPace: easyPace)
        case .fartlek:
            guard let f = parseFartlek(session.intervals) else { return nil }
            return fartlek(reps: f.reps, onS: f.onS, floatS: f.floatS, hardPace: vo2Pace, floatPace: easyPace)
        case .hills:
            guard let h = parseTimedReps(session.intervals, keyword: "hill") else { return nil }
            return hills(reps: h.reps, pushS: h.seconds, easyPace: easyPace)
        case .strides:
            let st = parseTimedReps(session.intervals, keyword: "stride") ?? (reps: 6, seconds: 20)
            return strides(reps: st.reps, strideS: st.seconds, easyPace: easyPace, totalDistanceM: session.targetDistanceM)
        case .progression:
            // The classic E→M→T ladder: thirds at easy, marathon, then threshold effort.
            return progression(totalDistanceM: session.targetDistanceM ?? 0, easyPace: easyPace,
                               moderatePace: DanielsPaces.marathonPaceSPerKm(p5kSPerKm: p5k),
                               strongPace: PlanEngine.pace(.tempo, p5k: p5k))
        case .long:
            // A quality long run ("Last 5km @ race pace") guides its finish block; a plain long run
            // needs no structure. Race pace comes from the goal distance when known; a long-race
            // default (marathon) stands in otherwise — this pattern only generates for ≥half plans.
            guard let finishM = parseRaceFinish(session.intervals) else { return nil }
            // The finish block runs at the plan's GOAL pace when one is set (2026-08-28).
            let racePace = goalRacePaceSPerKm
                ?? DanielsPaces.racePaceSPerKm(distanceM: raceDistanceM ?? 42_195, p5kSPerKm: p5k)
            return raceFinishLong(totalDistanceM: session.targetDistanceM ?? 0, finishM: finishM,
                                  bodyPace: pace, racePace: racePace)
        default:
            // Beginner "Run/walk 1:1" sessions are a repeating structure worth guiding.
            if let rw = parseRunWalk(session.intervals) {
                return runWalk(runS: rw.runS, walkS: rw.walkS, runPaceSPerKm: easyPace,
                               totalDistanceM: session.targetDistanceM,
                               totalDurationS: session.targetDurationS)
            }
            return nil
        }
    }
}
