import Foundation
import SwiftData

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
        let value = GeneratedSession(dayOffset: 0, discipline: session.discipline,
                                     runType: session.runType, targetDistanceM: session.targetDistanceM,
                                     targetDurationS: session.targetDurationS, targetPaceSPerKm: session.targetPaceSPerKm,
                                     intervals: session.intervals)
        return build(from: value, p5kSPerKm: p5kSPerKm, raceDistanceM: raceDistanceM,
                     goalRacePaceSPerKm: goalRacePaceSPerKm)
    }

    /// The generator and live runner expand the same value prescription.
    static func build(from session: GeneratedSession, p5kSPerKm: Double? = nil,
                      raceDistanceM: Double? = nil, goalRacePaceSPerKm: Double? = nil) -> StructuredWorkout? {
        guard let raw = unbounded(from: session, p5kSPerKm: p5kSPerKm, raceDistanceM: raceDistanceM,
                                  goalRacePaceSPerKm: goalRacePaceSPerKm) else { return nil }
        let p5k = p5kSPerKm ?? DanielsPaces.p5kSPerKm(fromPace: session.targetPaceSPerKm ?? 360,
                                                     type: session.runType ?? .easy)
        return RunPrescriptionBudget.fit(raw, distanceM: session.targetDistanceM,
                                         durationS: session.targetDurationS,
                                         easyPace: PlanEngine.pace(.easy, p5k: p5k))
    }

    private static func unbounded(from session: GeneratedSession, p5kSPerKm: Double?,
                                  raceDistanceM: Double?, goalRacePaceSPerKm: Double?) -> StructuredWorkout? {
        guard session.discipline == .running,
              let runType = session.runType,
              let pace = session.targetPaceSPerKm, pace > 0 else { return nil }

        let p5k = p5kSPerKm ?? DanielsPaces.p5kSPerKm(fromPace: pace, type: runType)
        let easyPace = PlanEngine.pace(.easy, p5k: p5k)
        let recoveryPace = PlanEngine.pace(.recovery, p5k: p5k)
        let vo2Pace = PlanEngine.pace(.intervals, p5k: p5k)   // vVO₂max — surges / by-feel hard bits

        if let testM = PlanEngine.timeTrialDistanceM(intervals: session.intervals) {
            return StructuredWorkout(title: "Time trial", steps: [
                WorkoutStep(kind: .work, target: .distance(testM), paceSPerKm: pace, title: "Time trial")
            ])
        }
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
            guard let finishM = parseRaceFinish(session.intervals) else {
                // A new runner's long run carries the same run/walk structure their easy days do
                // (2026-08-30) — it is the run that most needs it, and without this the guided
                // runner would show the note and then offer no structure behind it. Run portions
                // go at LONG pace, not easy pace: it is still the long run.
                if let rw = parseRunWalk(session.intervals) {
                    return runWalk(runS: rw.runS, walkS: rw.walkS, runPaceSPerKm: pace,
                                   totalDistanceM: session.targetDistanceM,
                                   totalDurationS: session.targetDurationS)
                }
                return nil
            }
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

/// The same complete dose is used by generation, the summary and execution. Time-based recovery
/// has distance too; warm-up and cooldown never sit outside the athlete's stated budget.
enum RunPrescriptionBudget {
    /// Reapply explicit availability after pace changes and manual edits, in the same save.
    static func enforcePreferences(in context: ModelContext) throws {
        guard context.container.schema.entities.contains(where: { $0.name == "PlanPreferencesRecord" }) else { return }
        let preferences = try context.fetch(FetchDescriptor<PlanPreferencesRecord>())
        guard preferences.contains(where: { $0.regularRunLimitS != nil || $0.longRunLimitS != nil }) else { return }
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        for profile in profiles {
            guard let plan = profile.plan, let prefs = preferences.first(where: { $0.profileID == profile.id }) else { continue }
            let unit = DistanceUnit(rawValue: profile.distanceUnit) ?? .auto
            for session in plan.sessions where (session.status == .planned || session.status == .moved) && session.completedWorkout == nil {
                let limit = session.runType == .long ? prefs.longRunLimitS : prefs.regularRunLimitS
                guard limit != nil else { continue }
                let source = GeneratedSession(dayOffset: 0, discipline: session.discipline, runType: session.runType,
                    targetDistanceM: session.targetDistanceM, targetDurationS: session.targetDurationS,
                    targetPaceSPerKm: session.targetPaceSPerKm, intervals: session.intervals, rationale: session.rationale)
                let value = constrain(source, p5k: plan.p5kSPerKm, raceDistanceM: profile.raceDistanceM,
                                      goalPace: plan.goalRacePaceSPerKm, limitS: limit, unit: unit)
                session.runType = value.runType; session.targetDistanceM = value.targetDistanceM
                session.targetDurationS = value.targetDurationS; session.targetPaceSPerKm = value.targetPaceSPerKm
                session.intervals = value.intervals; session.rationale = value.rationale
            }
        }
    }

    static func duration(_ workout: StructuredWorkout, easyPace: Double) -> Double {
        workout.steps.reduce(0) { total, step in
            switch step.target {
            case .duration(let seconds): return total + seconds
            case .distance(let meters): return total + meters / 1000 * (step.paceSPerKm ?? easyPace)
            }
        }
    }
    static func distance(_ workout: StructuredWorkout, easyPace: Double) -> Double {
        workout.steps.reduce(0) { total, step in
            switch step.target {
            case .distance(let meters): return total + meters
            case .duration(let seconds): return total + seconds / (step.paceSPerKm ?? easyPace) * 1000
            }
        }
    }

    static func fit(_ original: StructuredWorkout, distanceM: Double?, durationS: Double?,
                    easyPace: Double) -> StructuredWorkout {
        let maxM = distanceM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? .infinity
        let maxS = durationS.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? .infinity
        func fits(_ w: StructuredWorkout) -> Bool {
            distance(w, easyPace: easyPace) <= maxM + 0.01 && duration(w, easyPace: easyPace) <= maxS + 0.01
        }
        func easy() -> StructuredWorkout {
            let meters = max(1, min(maxM, maxS / easyPace * 1000, distance(original, easyPace: easyPace)))
            return StructuredWorkout(title: "Easy run", steps: [
                WorkoutStep(kind: .work, target: .distance(meters), paceSPerKm: easyPace)
            ])
        }
        guard easyPace.isFinite, easyPace > 0 else { return original }
        if original.title == "Time trial", !fits(original) { return easy() }
        var result = original
        // Shorten a repeat session by removing WHOLE reps and the recovery belonging to them.
        // Warm-up/cooldown remain intact. If one complete rep won't fit, prescribe an easy run.
        while !fits(result) {
            let reps = result.steps.indices.filter { result.steps[$0].kind == .work && result.steps[$0].repIndex != nil }
            guard let last = reps.last else { break }
            guard reps.count > 1 else { return easy() }
            let cooldown = result.steps.filter { $0.kind == .cooldown }
            result.steps = Array(result.steps.prefix(last))
            while result.steps.last?.kind == .recovery { result.steps.removeLast() }
            result.steps += cooldown
            let count = reps.count - 1
            for i in result.steps.indices where result.steps[i].repIndex != nil { result.steps[i].repTotal = count }
        }
        if !fits(result) {
            // Continuous work can shrink inside unchanged warm-up/cooldown boundaries.
            let fixed = StructuredWorkout(title: "", steps: result.steps.filter { $0.kind != .work })
            let work = StructuredWorkout(title: "", steps: result.steps.filter { $0.kind == .work })
            let factor = min(1, (maxM - distance(fixed, easyPace: easyPace)) / max(1, distance(work, easyPace: easyPace)),
                             (maxS - duration(fixed, easyPace: easyPace)) / max(1, duration(work, easyPace: easyPace)))
            guard factor > 0 else { return easy() }
            for i in result.steps.indices where result.steps[i].kind == .work {
                switch result.steps[i].target {
                case .distance(let meters): result.steps[i].target = .distance(meters * factor)
                case .duration(let seconds): result.steps[i].target = .duration(seconds * factor)
                }
            }
        }
        // Any unused distance is EASY cooldown, only within the remaining time budget.
        let remainingM = min(maxM - distance(result, easyPace: easyPace),
                             (maxS - duration(result, easyPace: easyPace)) / easyPace * 1000)
        if remainingM.isFinite, remainingM > 1 {
            if let last = result.steps.indices.last, result.steps[last].kind == .cooldown,
               case .distance(let d) = result.steps[last].target {
                result.steps[last].target = .distance(d + remainingM)
            } else {
                result.steps.append(WorkoutStep(kind: .cooldown, target: .distance(remainingM), paceSPerKm: easyPace))
            }
        }
        if let total = result.steps.first(where: { $0.repTotal != nil })?.repTotal {
            result.title = "\(total) repeats"
        }
        return result
    }

    static func constrain(_ source: GeneratedSession, p5k: Double, raceDistanceM: Double?,
                          goalPace: Double?, limitS: Double?, unit: DistanceUnit = .metric) -> GeneratedSession {
        guard source.discipline == .running, source.runType != .race else { return source }
        var result = source
        if let limitS, limitS.isFinite, limitS > 0 {
            result.targetDurationS = min(result.targetDurationS ?? limitS, limitS)
        }
        let easyPace = PlanEngine.pace(.easy, p5k: p5k)
        if let testM = PlanEngine.timeTrialDistanceM(intervals: result.intervals),
           (testM > (result.targetDistanceM ?? testM) + 0.01
            || testM / 1000 * (result.targetPaceSPerKm ?? easyPace) > (result.targetDurationS ?? .infinity)) {
            result.runType = .easy; result.isHardRun = false; result.intervals = nil
            result.targetPaceSPerKm = RunRounding.snapPace(sPerKm: easyPace, unit: unit, type: .easy)
            result.rationale = "The full checkpoint does not fit this week's budget. Keep this run easy; a later complete effort can calibrate your paces."
        }
        if let guided = StructuredWorkoutBuilder.build(from: result, p5kSPerKm: p5k,
                                                       raceDistanceM: raceDistanceM, goalRacePaceSPerKm: goalPace) {
            if guided.title == "Easy run" {
                result.runType = .easy; result.isHardRun = false; result.intervals = nil
                result.targetPaceSPerKm = RunRounding.snapPace(sPerKm: easyPace, unit: unit, type: .easy)
                result.rationale = "An easy run fits today's training budget. The warm-up and recovery are part of the workout."
            } else if let count = guided.steps.first(where: { $0.repTotal != nil })?.repTotal,
                      let text = result.intervals,
                      let separator = text.firstIndex(where: { $0 == "×" || $0 == "x" || $0 == "X" }) {
                result.intervals = "\(count)" + text[separator...]
            }
            result.targetDistanceM = min(result.targetDistanceM ?? .infinity, distance(guided, easyPace: easyPace))
            if result.targetDurationS != nil { result.targetDurationS = min(result.targetDurationS!, duration(guided, easyPace: easyPace)) }
        } else if let limitS, let pace = result.targetPaceSPerKm, pace > 0 {
            result.targetDistanceM = min(result.targetDistanceM ?? .infinity, limitS / pace * 1000)
            result.targetDurationS = limitS
        }
        if let limit = result.targetDurationS, let pace = result.targetPaceSPerKm,
           result.runType == .easy || result.runType == .recovery || (result.runType == .long && result.intervals == nil) {
            result.targetDistanceM = min(result.targetDistanceM ?? .infinity, limit / pace * 1000)
        }
        return result
    }
}
