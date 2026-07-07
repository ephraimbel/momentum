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

struct WorkoutStep: Equatable, Sendable {
    enum Kind: String, Sendable {
        case warmup, work, recovery, cooldown

        /// The effort steps where pace adherence matters (and iridescence can appear).
        var isWork: Bool { self == .work }
    }

    /// How the step ends — cover a distance, or hold for a duration.
    enum Target: Equatable, Sendable {
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

    /// "Warm up" / "Rep" / "Recovery" / "Cool down" — the short label for the live banner.
    var kindLabel: String {
        switch kind {
        case .warmup: "Warm up"
        case .work: repTotal != nil ? "Rep" : "Work"
        case .recovery: "Recovery"
        case .cooldown: "Cool down"
        }
    }
}

struct StructuredWorkout: Equatable, Sendable {
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

    /// Expand a planned session into a guided workout, or `nil` when it's a plain run (easy / long /
    /// recovery / free) that needs no in-run structure. Only running sessions with a known target pace
    /// qualify. Pure + deterministic.
    static func build(from session: PlannedSession) -> StructuredWorkout? {
        guard session.discipline == .running,
              let runType = session.runType,
              let pace = session.targetPaceSPerKm, pace > 0 else { return nil }

        switch runType {
        case .intervals:
            guard let spec = parseIntervals(session.intervals) else { return nil }
            return intervals(reps: spec.reps, repDistanceM: spec.distanceM, intervalPaceSPerKm: pace)
        case .tempo:
            return tempo(totalDistanceM: session.targetDistanceM ?? 0, tempoPaceSPerKm: pace)
        default:
            // Beginner "Run/walk 1:1" sessions are a repeating structure worth guiding.
            if let rw = parseRunWalk(session.intervals) {
                return runWalk(runS: rw.runS, walkS: rw.walkS, runPaceSPerKm: pace,
                               totalDistanceM: session.targetDistanceM,
                               totalDurationS: session.targetDurationS)
            }
            return nil
        }
    }

    // MARK: Interval session

    /// warm-up → (rep @ interval pace + easy recovery)×N → cool-down. Interval pace carries offset 0
    /// (= P5k); recovery and warm-up/cool-down derive from the standard offsets (§9.1).
    static func intervals(reps: Int, repDistanceM: Double, intervalPaceSPerKm p: Double) -> StructuredWorkout {
        let recoveryPace = p + 110   // .recovery offset relative to P5k (== interval pace)
        let easyPace = p + 80        // .easy offset
        let recoveryS = repDistanceM <= 400 ? 90.0 : 120.0

        var steps: [WorkoutStep] = [
            WorkoutStep(kind: .warmup, target: .distance(warmupM), paceSPerKm: easyPace)
        ]
        for i in 1...max(1, reps) {
            steps.append(WorkoutStep(kind: .work, target: .distance(repDistanceM),
                                     paceSPerKm: p, repIndex: i, repTotal: reps))
            if i < reps {
                steps.append(WorkoutStep(kind: .recovery, target: .duration(recoveryS), paceSPerKm: recoveryPace))
            }
        }
        steps.append(WorkoutStep(kind: .cooldown, target: .distance(cooldownM), paceSPerKm: easyPace))

        let repM = repDistanceM < 1000 ? "\(Int(repDistanceM))m" : "\(trim(repDistanceM / 1000))km"
        return StructuredWorkout(title: "\(reps)×\(repM) intervals", steps: steps)
    }

    // MARK: Tempo session

    /// warm-up → one tempo block → cool-down, preserving the engine's total distance. Warm-up/cool-down
    /// shrink for short sessions so the tempo block never vanishes.
    static func tempo(totalDistanceM total: Double, tempoPaceSPerKm p: Double) -> StructuredWorkout? {
        guard total > 0 else { return nil }
        let easyPace = p + 60                        // tempo carries +20 vs P5k → easy is +60 vs tempo
        let wu = min(warmupM, total * 0.2)
        let cd = min(cooldownM, total * 0.2)
        let block = max(1000, total - wu - cd)
        let steps: [WorkoutStep] = [
            WorkoutStep(kind: .warmup, target: .distance(wu), paceSPerKm: easyPace),
            WorkoutStep(kind: .work, target: .distance(block), paceSPerKm: p, toleranceSPerKm: 8),
            WorkoutStep(kind: .cooldown, target: .distance(cd), paceSPerKm: easyPace)
        ]
        return StructuredWorkout(title: "Tempo run", steps: steps)
    }

    // MARK: Run/walk (beginner)

    /// Alternating run/walk intervals for the session's duration (or distance-implied duration). The
    /// run leg carries the easy pace; the walk leg is by feel.
    static func runWalk(runS: Double, walkS: Double, runPaceSPerKm p: Double,
                        totalDistanceM: Double?, totalDurationS: Double?) -> StructuredWorkout {
        // Total time = explicit duration, else distance ÷ easy pace (s/km × km).
        let totalS = totalDurationS
            ?? (totalDistanceM.map { $0 / 1000 * p } ?? (runS + walkS) * 8)
        let cycles = max(1, min(40, Int((totalS / (runS + walkS)).rounded())))
        var steps: [WorkoutStep] = []
        for _ in 0..<cycles {
            steps.append(WorkoutStep(kind: .work, target: .duration(runS), paceSPerKm: p))
            steps.append(WorkoutStep(kind: .recovery, target: .duration(walkS), paceSPerKm: nil))
        }
        return StructuredWorkout(title: "Run/walk intervals", steps: steps)
    }

    // MARK: Parsing

    /// "6×400m @ 5K pace" / "5x800m" / "4×1km" / "3×1.5km" → (reps, distanceM). Accepts × / x / X as the
    /// separator and honors the unit: a `km`/`k` suffix scales to meters (so "1km" is 1000 m, not 1 m).
    static func parseIntervals(_ s: String?) -> (reps: Int, distanceM: Double)? {
        guard let s else { return nil }
        let normalized = s.replacingOccurrences(of: "×", with: "x")
                          .replacingOccurrences(of: "X", with: "x")
        let parts = normalized.split(separator: "x", maxSplits: 1)
        guard parts.count == 2,
              let reps = Int(parts[0].trimmingCharacters(in: .whitespaces)), reps > 0 else { return nil }
        // The rep distance + unit from the second part: skip to the first digit, read the number
        // (allowing a decimal), then look at the unit that immediately follows.
        let tail = parts[1].drop { !$0.isNumber }
        let numStr = tail.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(numStr), value > 0 else { return nil }
        let unit = tail.dropFirst(numStr.count).trimmingCharacters(in: .whitespaces).lowercased()
        let meters = unit.hasPrefix("k") ? value * 1000 : value   // "km"/"k" → meters; default is meters
        return (reps, meters)
    }

    /// "Run/walk 1:1" → run/walk seconds (the ratio is read as minutes). Defaults to 1:1 minutes.
    static func parseRunWalk(_ s: String?) -> (runS: Double, walkS: Double)? {
        guard let s, s.lowercased().contains("run/walk") else { return nil }
        let nums = s.split { !$0.isNumber }.compactMap { Double($0) }
        if nums.count >= 2, nums[0] > 0, nums[1] > 0 { return (nums[0] * 60, nums[1] * 60) }
        return (60, 60)
    }

    /// Trim a trailing ".0" so "0.4km" reads cleanly; keep one decimal otherwise.
    private static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - Live progress tracker

/// Pure progress logic for a structured run. Given cumulative distance + elapsed time it decides which
/// step you're in, how much remains, and whether you're on pace. No timers, no I/O — the view model
/// drives it once a second and voices the transitions it reports.
struct StructuredRunTracker: Equatable, Sendable {
    enum Adherence: Equatable, Sendable { case onPace, tooFast, tooSlow, noTarget }

    let steps: [WorkoutStep]
    private(set) var index = 0
    /// Cumulative distance / elapsed captured when the current step began.
    private(set) var anchorDistanceM = 0.0
    private(set) var anchorElapsedS = 0.0

    init(steps: [WorkoutStep]) { self.steps = steps }

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
