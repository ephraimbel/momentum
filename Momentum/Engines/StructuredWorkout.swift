import Foundation

/// Real-time structured-workout guidance (running-excellence R1, PRD §4.3/§9). A prescribed quality
/// session — "6×400m @ 5K pace", a tempo, a beginner run/walk — is expanded into an ordered list of
/// `WorkoutStep`s that the live recorder guides the athlete through: warm-up → (work + recovery)×N →
/// cool-down, with a target pace per step and per-step cues.
///
/// Deterministic and pure (no SwiftData / AVFoundation) so it's unit-testable. Loads and paces come
/// from `PlanEngine`; warm-up/cool-down and recovery jogs are fixed *execution* conventions layered
/// on top of the engine's prescription — they never invent new training load.

// MARK: - Step model

struct WorkoutStep: Equatable, Sendable, Codable {
    enum Kind: String, Sendable, Codable {
        case warmup, work, recovery, cooldown

        /// The effort steps where pace adherence matters (and iridescence can appear).
        var isWork: Bool { self == .work }
    }

    /// How the step ends — cover a distance, or hold for a duration.
    enum Target: Equatable, Sendable, Codable {
        case distance(Double)   // meters
        case duration(Double)   // seconds

        var distanceM: Double { if case let .distance(d) = self { d } else { 0 } }
        var isTime: Bool { if case .duration = self { true } else { false } }
    }

    var kind: Kind
    var target: Target
    /// Target pace for the step (s/km). nil → run by feel (open warm-up / cool-down / walk break).
    var paceSPerKm: Double?
    /// Half-width of the on-pace band (s/km). Outside it the coach nudges faster / slower.
    var toleranceSPerKm: Double = 12
    /// Rep position within a work group, e.g. 3 of 6. nil for non-rep steps (warm-up, tempo block).
    var repIndex: Int?
    var repTotal: Int?
    /// Custom noun for specialty steps — "Hill", "Stride", "Surge", "Float", "Push". nil → the kind label.
    var title: String? = nil

    /// "Warm up" / "Rep" / "Recovery" / "Cool down" — the short label for the live banner.
    var kindLabel: String {
        switch kind {
        case .warmup: "Warm up"
        case .work: repTotal != nil ? "Rep" : "Work"
        case .recovery: "Recovery"
        case .cooldown: "Cool down"
        }
    }

    /// The noun used in the banner/cue — the custom `title` when set, else the kind label.
    var displayNoun: String { title ?? kindLabel }
}

struct StructuredWorkout: Equatable, Sendable, Codable {
    var title: String
    var steps: [WorkoutStep]

    var workStepCount: Int { steps.filter { $0.kind == .work }.count }

    /// Total prescribed distance across steps whose target is a distance (m). Duration steps (timed
    /// recoveries/warm-ups) aren't counted since their distance depends on how fast you run them.
    var plannedDistanceM: Double { steps.reduce(0) { $0 + $1.target.distanceM } }
}

// MARK: - Builder (session → steps)

enum StructuredWorkoutBuilder {

    /// Warm-up / cool-down distance for a quality session (m).
    private static let warmupM = 1000.0
    private static let cooldownM = 1000.0

    // NOTE: `build(from: PlannedSession)` — the SwiftData-facing entry — lives in
    // `StructuredWorkoutBuilder+Session.swift`. This file stays pure Foundation so the step
    // model, tracker, and constructors compile into the watch target too.

    // MARK: Interval session (distance or time reps)

    static func intervals(reps: Int, repTarget: WorkoutStep.Target, repPace: Double,
                          easyPace: Double, recoveryPace: Double, unitLabel: String,
                          recoveryOverrideS: Double? = nil) -> StructuredWorkout {
        let recoveryS = recoveryOverrideS ?? recoveryDuration(for: repTarget)
        var steps: [WorkoutStep] = [WorkoutStep(kind: .warmup, target: .distance(warmupM), paceSPerKm: easyPace)]
        for i in 1...max(1, reps) {
            steps.append(WorkoutStep(kind: .work, target: repTarget, paceSPerKm: repPace, repIndex: i, repTotal: reps))
            if i < reps {
                steps.append(WorkoutStep(kind: .recovery, target: .duration(recoveryS), paceSPerKm: recoveryPace))
            }
        }
        steps.append(WorkoutStep(kind: .cooldown, target: .distance(cooldownM), paceSPerKm: easyPace))
        return StructuredWorkout(title: "\(reps)×\(unitLabel) intervals", steps: steps)
    }

    private static func recoveryDuration(for t: WorkoutStep.Target) -> Double {
        switch t {
        case let .distance(d):
            // The coach's rest ladder: 400s take a 90 s jog, 800s ~2:30, kilometre reps a full
            // 3:00. Short-changing the rest on long VO₂ reps is how the session quietly collapses
            // into a ragged tempo — the recovery IS part of the prescription.
            if d <= 400 { return 90 }
            if d <= 800 { return 150 }
            return 180
        case let .duration(s): return max(60, s)   // roughly equal-time recovery for time reps
        }
    }

    // MARK: Tempo

    static func tempo(totalDistanceM total: Double, tempoPaceSPerKm p: Double, easyPace: Double) -> StructuredWorkout? {
        guard total > 0 else { return nil }
        let wu = min(warmupM, total * 0.2), cd = min(cooldownM, total * 0.2)
        let block = max(1000, total - wu - cd)
        return StructuredWorkout(title: "Tempo run", steps: [
            WorkoutStep(kind: .warmup, target: .distance(wu), paceSPerKm: easyPace),
            WorkoutStep(kind: .work, target: .distance(block), paceSPerKm: p, toleranceSPerKm: 8),
            WorkoutStep(kind: .cooldown, target: .distance(cd), paceSPerKm: easyPace)
        ])
    }

    // MARK: Fartlek — warm-up → (hard surge + easy float)×N → cool-down. Surges ~3k effort; float easy.

    static func fartlek(reps: Int, onS: Double, floatS: Double, hardPace: Double, floatPace: Double) -> StructuredWorkout {
        var steps: [WorkoutStep] = [WorkoutStep(kind: .warmup, target: .distance(warmupM), paceSPerKm: floatPace)]
        for i in 1...max(1, reps) {
            steps.append(WorkoutStep(kind: .work, target: .duration(onS), paceSPerKm: hardPace,
                                     toleranceSPerKm: 25, repIndex: i, repTotal: reps, title: "Surge"))
            steps.append(WorkoutStep(kind: .recovery, target: .duration(floatS), paceSPerKm: floatPace, title: "Float"))
        }
        steps.append(WorkoutStep(kind: .cooldown, target: .distance(cooldownM), paceSPerKm: floatPace))
        return StructuredWorkout(title: "Fartlek · \(reps)×\(secLabel(onS))", steps: steps)
    }

    // MARK: Hills — warm-up → (uphill push + jog-down recovery)×N → cool-down. Effort-based (no pace).

    static func hills(reps: Int, pushS: Double, easyPace: Double) -> StructuredWorkout {
        var steps: [WorkoutStep] = [WorkoutStep(kind: .warmup, target: .distance(warmupM), paceSPerKm: easyPace)]
        for i in 1...max(1, reps) {
            steps.append(WorkoutStep(kind: .work, target: .duration(pushS), paceSPerKm: nil,
                                     repIndex: i, repTotal: reps, title: "Hill"))
            // A hard push earns a real reset — never less than 90 s even off a short hill.
            steps.append(WorkoutStep(kind: .recovery, target: .duration(max(90, pushS * 1.6)),
                                     paceSPerKm: easyPace, title: "Jog down"))
        }
        steps.append(WorkoutStep(kind: .cooldown, target: .distance(cooldownM), paceSPerKm: easyPace))
        return StructuredWorkout(title: "Hill reps · \(reps)×\(secLabel(pushS))", steps: steps)
    }

    // MARK: Strides — an easy run capped with short, fast, relaxed accelerations. Effort-based.

    static func strides(reps: Int, strideS: Double, easyPace: Double, totalDistanceM: Double?) -> StructuredWorkout {
        let easyM = max(1500, (totalDistanceM ?? 4000) - 800)   // the bulk is the easy run; strides tack on
        var steps: [WorkoutStep] = [WorkoutStep(kind: .warmup, target: .distance(easyM), paceSPerKm: easyPace)]
        for i in 1...max(1, reps) {
            steps.append(WorkoutStep(kind: .work, target: .duration(strideS), paceSPerKm: nil,
                                     repIndex: i, repTotal: reps, title: "Stride"))
            if i < reps {
                // A full minute's walk — strides are practice, not load; each one starts fresh.
                steps.append(WorkoutStep(kind: .recovery, target: .duration(60), paceSPerKm: nil, title: "Walk back"))
            }
        }
        return StructuredWorkout(title: "Easy run + \(reps) strides", steps: steps)
    }

    // MARK: Race-pace finish long run — the signature half/marathon workout (Canova/Daniels):
    // a steady long-run body, then the final kilometres at goal race pace on tired legs. Two blocks,
    // no warm-up step (the body IS the warm-up).

    static func raceFinishLong(totalDistanceM total: Double, finishM: Double,
                               bodyPace: Double, racePace: Double) -> StructuredWorkout? {
        guard total > 0, finishM >= 1_000, finishM < total else { return nil }
        let km = Int((finishM / 1000).rounded())
        return StructuredWorkout(title: "Long run · last \(km)km @ race pace", steps: [
            WorkoutStep(kind: .work, target: .distance(total - finishM), paceSPerKm: bodyPace,
                        toleranceSPerKm: 20, title: "Steady"),
            WorkoutStep(kind: .work, target: .distance(finishM), paceSPerKm: racePace,
                        toleranceSPerKm: 10, title: "Race pace")
        ])
    }

    // MARK: Progression — one continuous run split into thirds: easy → marathon → threshold effort.
    // The classic E→M→T ladder: each third steps up one Daniels zone, always in a faster-than-the-last
    // order regardless of the athlete's VDOT (E 66% < M race intensity < T ~89% VO₂max).

    static func progression(totalDistanceM total: Double, easyPace: Double,
                            moderatePace moderate: Double, strongPace strong: Double) -> StructuredWorkout? {
        guard total >= 3000 else { return nil }
        let third = (total / 3).rounded()
        return StructuredWorkout(title: "Progression run", steps: [
            WorkoutStep(kind: .work, target: .distance(third), paceSPerKm: easyPace, toleranceSPerKm: 25, title: "Easy"),
            WorkoutStep(kind: .work, target: .distance(third), paceSPerKm: moderate, toleranceSPerKm: 15, title: "Moderate"),
            WorkoutStep(kind: .work, target: .distance(total - 2 * third), paceSPerKm: strong, toleranceSPerKm: 12, title: "Strong")
        ])
    }

    // MARK: Run/walk (beginner)

    static func runWalk(runS: Double, walkS: Double, runPaceSPerKm p: Double,
                        totalDistanceM: Double?, totalDurationS: Double?) -> StructuredWorkout {
        let totalS = totalDurationS
            ?? (totalDistanceM.map { $0 / 1000 * p } ?? (runS + walkS) * 8)
        let cycles = max(1, min(40, Int((totalS / (runS + walkS)).rounded())))
        var steps: [WorkoutStep] = []
        for _ in 0..<cycles {
            // No pace target on the run segments — run/walk guides by TIME and feel, and a
            // beginner must never hear "pick it up" mid-interval (no-shame, PRD principle).
            // Named steps so every surface says the plain thing: Run. Walk. Run.
            steps.append(WorkoutStep(kind: .work, target: .duration(runS), paceSPerKm: nil, title: "Run"))
            steps.append(WorkoutStep(kind: .recovery, target: .duration(walkS), paceSPerKm: nil, title: "Walk"))
        }
        return StructuredWorkout(title: "Run/walk intervals", steps: steps)
    }

    // MARK: Parsing

    /// "6×400m @ 5K" / "5x800m" / "4×1km" → (reps, distanceM). Rejects time units ("min"/"sec") so a
    /// time-rep string falls through to `parseTimeReps`.
    static func parseIntervals(_ s: String?) -> (reps: Int, distanceM: Double)? {
        guard let s else { return nil }
        let normalized = s.replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: "X", with: "x")
        let parts = normalized.split(separator: "x", maxSplits: 1)
        guard parts.count == 2,
              let reps = Int(parts[0].trimmingCharacters(in: .whitespaces)), reps > 0 else { return nil }
        let tail = parts[1].drop { !$0.isNumber }
        let numStr = tail.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(numStr), value > 0 else { return nil }
        let unit = tail.dropFirst(numStr.count).prefix { $0.isLetter }.lowercased()
        if unit == "min" || unit == "sec" || unit == "s" { return nil }   // time reps, not distance
        let meters = unit.hasPrefix("k") ? value * 1000 : value           // "km"/"k" → meters
        return (reps, meters)
    }

    /// "5×3min @ VO2" → (reps, seconds). Only matches when a "min" unit is present.
    static func parseTimeReps(_ s: String?) -> (reps: Int, seconds: Double)? {
        guard let s, s.lowercased().contains("min") else { return nil }
        let norm = s.replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: "X", with: "x")
        let parts = norm.split(separator: "x", maxSplits: 1)
        guard parts.count == 2, let reps = Int(parts[0].filter(\.isNumber)), reps > 0 else { return nil }
        guard let sec = durationsIn(String(parts[1])).first else { return nil }
        return (reps, sec)
    }

    /// "8×45sec hills" / "6×20sec strides" → (reps, seconds), gated on the `keyword`.
    static func parseTimedReps(_ s: String?, keyword: String) -> (reps: Int, seconds: Double)? {
        guard let s, s.lowercased().contains(keyword) else { return nil }
        let norm = s.replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: "X", with: "x")
        let parts = norm.split(separator: "x", maxSplits: 1)
        guard parts.count == 2, let reps = Int(parts[0].filter(\.isNumber)), reps > 0 else { return nil }
        guard let sec = durationsIn(String(parts[1])).first else { return nil }
        return (reps, sec)
    }

    /// "8×(1min hard / 1min float)" → (reps, onS, floatS).
    static func parseFartlek(_ s: String?) -> (reps: Int, onS: Double, floatS: Double)? {
        guard let s else { return nil }
        let norm = s.replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: "X", with: "x")
        let parts = norm.split(separator: "x", maxSplits: 1)
        guard parts.count == 2, let reps = Int(parts[0].filter(\.isNumber)), reps > 0 else { return nil }
        let durs = durationsIn(String(parts[1]))
        guard durs.count >= 2 else { return nil }
        return (reps, durs[0], durs[1])
    }

    /// "Last 5km @ race pace" → finish-block meters. Gated on "last" + "race pace" so a plain long
    /// run (nil/other intervals) falls through to unguided.
    static func parseRaceFinish(_ s: String?) -> Double? {
        guard let s = s?.lowercased(), s.contains("last"), s.contains("race pace") else { return nil }
        let tail = s.drop { !$0.isNumber }
        let numStr = tail.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(numStr), value > 0 else { return nil }
        let unit = tail.dropFirst(numStr.count).prefix { $0.isLetter }.lowercased()
        return unit.hasPrefix("k") ? value * 1000 : value
    }

    /// "Run/walk 1:1" → run/walk seconds (the ratio is read as minutes). Defaults to 1:1 minutes.
    static func parseRunWalk(_ s: String?) -> (runS: Double, walkS: Double)? {
        guard let s, s.lowercased().contains("run/walk") else { return nil }
        let nums = s.split { !$0.isNumber }.compactMap { Double($0) }
        if nums.count >= 2, nums[0] > 0, nums[1] > 0 { return (nums[0] * 60, nums[1] * 60) }
        return (60, 60)
    }

    /// All `<n>min` / `<n>sec` durations in a string, in seconds and in order.
    private static func durationsIn(_ s: String) -> [Double] {
        var out: [Double] = []
        let chars = Array(s.lowercased())
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else { i += 1; continue }
            var num = ""
            while i < chars.count, chars[i].isNumber || chars[i] == "." { num.append(chars[i]); i += 1 }
            var unit = ""
            while i < chars.count, chars[i].isLetter { unit.append(chars[i]); i += 1 }
            guard let v = Double(num) else { continue }
            if unit.hasPrefix("min") { out.append(v * 60) }
            else if unit.hasPrefix("s") { out.append(v) }
        }
        return out
    }

    // MARK: Labels (internal — the session-facing builder file uses them too)

    static func repDistanceLabel(_ m: Double) -> String { m < 1000 ? "\(Int(m))m" : "\(trim(m / 1000))km" }
    /// Duration labels must round-trip EXACTLY through `durationsIn` — these strings are the
    /// session grammar, not just display. "1.2min" for 75 s parses back as 72 s (a corrupted
    /// prescription); sub-2-minute odd durations stay in seconds, whole/half minutes in minutes.
    static func secLabel(_ s: Double) -> String {
        if s >= 60, s.truncatingRemainder(dividingBy: 60) == 0 { return minLabel(s) }
        if s < 120 { return "\(Int(s))s" }
        return minLabel(s)
    }
    static func minLabel(_ s: Double) -> String {
        let m = s / 60
        return m == m.rounded() ? "\(Int(m))min" : String(format: "%.1fmin", m)
    }
    private static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - Live progress tracker

/// Pure progress logic for a structured run. Given cumulative distance + elapsed time it decides which
/// step you're in, how much remains, and whether you're on pace. No timers, no I/O — the view model
/// drives it once a second and voices the transitions it reports.
/// A completed work rep, captured live for the post-run adherence breakdown (running-excellence polish).
/// Codable so it persists on the workout and shows in history, not just the immediate summary.
struct RepResult: Codable, Sendable, Equatable {
    var repIndex: Int?
    var repTotal: Int?
    var title: String?
    var targetPaceSPerKm: Double?
    var toleranceSPerKm: Double = 12
    var achievedPaceSPerKm: Double
    var distanceM: Double
    var durationS: Double

    enum Verdict: String, Codable, Sendable { case onPace, tooFast, tooSlow, noTarget }
    /// Did the rep land in its target pace band? (Lower s/km = faster.)
    var verdict: Verdict {
        guard let t = targetPaceSPerKm, achievedPaceSPerKm > 0 else { return .noTarget }
        if achievedPaceSPerKm < t - toleranceSPerKm { return .tooFast }
        if achievedPaceSPerKm > t + toleranceSPerKm { return .tooSlow }
        return .onPace
    }
    /// A readable name for the rep ("Rep 3/6", "Hill 2/8", "Tempo").
    var label: String {
        let noun = title ?? "Rep"
        if let i = repIndex, let n = repTotal { return "\(noun) \(i)/\(n)" }
        return noun
    }
}

struct StructuredRunTracker: Equatable, Sendable {
    enum Adherence: Equatable, Sendable { case onPace, tooFast, tooSlow, noTarget }

    let steps: [WorkoutStep]
    private(set) var index = 0
    /// Cumulative distance / elapsed captured when the current step began.
    private(set) var anchorDistanceM = 0.0
    private(set) var anchorElapsedS = 0.0
    /// Per-rep results, appended as each work step is crossed — feeds the post-run breakdown.
    private(set) var completedReps: [RepResult] = []

    init(steps: [WorkoutStep]) { self.steps = steps }

    /// Capture the just-finished step as a rep result (work steps only). Called before the index advances,
    /// so `current`/anchors still describe the completing step.
    private mutating func recordRep(distanceM: Double, elapsedS: Double) {
        guard let step = current, step.kind.isWork else { return }
        let dist = distanceM - anchorDistanceM, dur = elapsedS - anchorElapsedS
        guard dist > 0, dur > 0 else { return }
        completedReps.append(RepResult(repIndex: step.repIndex, repTotal: step.repTotal, title: step.title,
                                       targetPaceSPerKm: step.paceSPerKm, toleranceSPerKm: step.toleranceSPerKm,
                                       achievedPaceSPerKm: dur / (dist / 1000), distanceM: dist, durationS: dur))
    }

    var isComplete: Bool { index >= steps.count }
    var current: WorkoutStep? { steps.indices.contains(index) ? steps[index] : nil }
    var next: WorkoutStep? { steps.indices.contains(index + 1) ? steps[index + 1] : nil }

    /// Remaining distance (m) or time (s) in the current step. 0 when complete.
    func remaining(distanceM: Double, elapsedS: Double) -> Double {
        guard let step = current else { return 0 }
        switch step.target {
        case let .distance(d): return max(0, d - (distanceM - anchorDistanceM))
        case let .duration(s): return max(0, s - (elapsedS - anchorElapsedS))
        }
    }

    /// Fraction 0…1 of the current step completed.
    func progress(distanceM: Double, elapsedS: Double) -> Double {
        guard let step = current else { return 1 }
        let total: Double
        switch step.target { case let .distance(d): total = d; case let .duration(s): total = s }
        guard total > 0 else { return 1 }
        return max(0, min(1, 1 - remaining(distanceM: distanceM, elapsedS: elapsedS) / total))
    }

    /// Advance past every step whose target is already met. Returns true if the step index changed —
    /// the caller voices the newly-entered step (or completion). Re-anchors at the crossing point.
    @discardableResult
    mutating func advance(distanceM: Double, elapsedS: Double) -> Bool {
        var changed = false
        while let step = current, targetMet(step, distanceM: distanceM, elapsedS: elapsedS) {
            recordRep(distanceM: distanceM, elapsedS: elapsedS)
            index += 1
            anchorDistanceM = distanceM
            anchorElapsedS = elapsedS
            changed = true
        }
        return changed
    }

    /// End the current step now (the Lap / Skip control). Returns true if a step was skipped.
    @discardableResult
    mutating func skip(distanceM: Double, elapsedS: Double) -> Bool {
        guard !isComplete else { return false }
        recordRep(distanceM: distanceM, elapsedS: elapsedS)   // partial rep still counts toward the breakdown
        index += 1
        anchorDistanceM = distanceM
        anchorElapsedS = elapsedS
        return true
    }

    private func targetMet(_ step: WorkoutStep, distanceM: Double, elapsedS: Double) -> Bool {
        switch step.target {
        case let .distance(d): return (distanceM - anchorDistanceM) >= d
        case let .duration(s): return (elapsedS - anchorElapsedS) >= s
        }
    }

    /// On-pace verdict for the current step from the live smoothed pace (s/km). Lower = faster.
    func adherence(currentPaceSPerKm pace: Double) -> Adherence {
        guard let step = current, step.kind.isWork, let target = step.paceSPerKm, pace > 0 else { return .noTarget }
        if pace < target - step.toleranceSPerKm { return .tooFast }
        if pace > target + step.toleranceSPerKm { return .tooSlow }
        return .onPace
    }
}
