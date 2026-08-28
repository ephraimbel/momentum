import Foundation

/// The live coach's judgement, pure and clocked by the caller: WHAT to say on a run and WHEN it
/// may be said. `CardioViewModel` feeds it fixes and ticks and owns the wall-clock tasks, haptics
/// and the voice; nothing here touches time itself, so a whole 14-mile run replays in a unit test
/// and the exact cue sequence and spacing can be pinned (`LiveCoachCadenceTests`).
///
/// Two halves:
/// - `CoachCueGate` — the spacing rule. One line at a time; a floor on how often the coach speaks;
///   transitions pre-empt, milestones wait their turn, ambient nudges are dropped rather than queued.
/// - `LiveRunCoach` — the run logic: splits, halfway / last unit / goal on a distance-goal run, the
///   drift nudge on a plan-paced run, and the in-step nudge + one "on pace" per step on a structured
///   session.
struct CoachCueGate: Equatable, Sendable {
    enum Priority: Int, Comparable, Sendable {
        case ambient = 0, milestone = 1, transition = 2
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    struct Line: Equatable, Sendable {
        enum Kind: Sendable { case intro, split, halfway, finalStretch, goal, nudge, encouragement, stepStart, complete, other }
        let text: String
        let priority: Priority
        var kind: Kind = .other
    }
    enum Decision: Equatable, Sendable {
        /// Say it now.
        case deliver
        /// Park it; say it once the spacing window closes (`delayS` from now) unless cleared.
        case park(delayS: TimeInterval)
        /// Nobody hears this one; the caller re-evaluates on its next tick.
        case drop
    }

    /// Minimum silence between cues (any priority below `transition`).
    static let spacingS: TimeInterval = 12
    /// How long a line stays on screen before it fades.
    static let dwellS: TimeInterval = 7

    private(set) var lastCueAt: TimeInterval = -.greatestFiniteMagnitude
    private(set) var pending: Line?

    mutating func admit(_ line: Line, at now: TimeInterval) -> Decision {
        guard !line.text.isEmpty else { return .drop }
        let since = now - lastCueAt
        if line.priority < .transition, since < Self.spacingS {
            switch line.priority {
            case .milestone:
                pending = line   // a newer milestone replaces an older one
                return .park(delayS: Self.spacingS - since)
            default:
                return .drop
            }
        }
        // A parked milestone is owed first: an ambient nudge arriving as the window closes must not
        // slip in ahead of it and wipe it (the split would never be heard).
        if line.priority == .ambient, pending != nil { return .drop }
        pending = nil
        lastCueAt = now
        return .deliver
    }

    /// The parked line, if still owed — stamps the clock as if spoken now.
    mutating func takePending(at now: TimeInterval) -> Line? {
        guard let p = pending else { return nil }
        pending = nil
        lastCueAt = now
        return p
    }

    /// A pause (or the finish) voids whatever was waiting: the moment has passed.
    mutating func clearPending() { pending = nil }
}

struct LiveRunCoach: Equatable, Sendable {
    typealias Line = CoachCueGate.Line
    typealias Adherence = StructuredRunTracker.Adherence

    // Tuning — every number a runner would feel.
    /// Off-band time before any drift nudge is allowed.
    static let driftHoldS: TimeInterval = 8
    /// Cooldown between nudges inside a structured step: a 400 m rep run slow all the way hears
    /// it twice at most, a 20-minute tempo block every minute and a half.
    static let nudgeCooldownS: TimeInterval = 90
    /// Cooldown between drift nudges on a plan-paced easy/long run.
    static let plannedNudgeCooldownS: TimeInterval = 120
    /// A planned run is never paced in its first minutes: the smoothed pace has to settle.
    static let plannedWarmupHoldS: TimeInterval = 180
    /// Planned-run band, s/km: leave it past ±outer, back inside under ±inner (hysteresis).
    static let plannedOuterBandSPerKm = 25.0
    static let plannedInnerBandSPerKm = 15.0
    /// A structured step is not paced for its first seconds (EMA catching up from the last step).
    static let stepSettleS: TimeInterval = 15
    static let encouragementAfterS: TimeInterval = 30
    static let encouragementSpacingS: TimeInterval = 240
    static let encouragementAfterNudgeS: TimeInterval = 60

    let unit: DistanceUnit
    let goalMeters: Double?
    let targetPaceSPerKm: Double?
    /// False for rides: the mile is called, the "per mile" figure is not (it would read as a
    /// running pace on a bike).
    let speaksSplitPace: Bool

    private var unitMeters: Double { unit.resolved() == .imperial ? Formatters.metersPerMile : 1000 }

    private(set) var lastUnitCount = 0
    private var lastBoundaryElapsedS: TimeInterval = 0
    private(set) var goalAnnounced = false
    private(set) var halfwayAnnounced = false
    private(set) var finalStretchAnnounced = false

    private var driftSince: TimeInterval?
    private var lastDriftDirection: Adherence = .noTarget
    private var lastPaceNudgeAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastEncouragementAt: TimeInterval = -.greatestFiniteMagnitude
    private var encouragementCount = 0
    private var encouragedStepIndex = -1

    init(unit: DistanceUnit, goalMeters: Double? = nil, targetPaceSPerKm: Double? = nil,
         speaksSplitPace: Bool = true) {
        self.unit = unit
        self.goalMeters = goalMeters
        self.targetPaceSPerKm = targetPaceSPerKm
        self.speaksSplitPace = speaksSplitPace
    }

    /// The opening line for a planned (non-structured) run, nil for a free run: silence is the norm.
    func plannedIntro() -> Line? {
        CoachingCueBuilder.runIntro(goalMeters: goalMeters, targetPaceSPerKm: targetPaceSPerKm, unit: unit)
            .map { Line(text: $0, priority: .transition, kind: .intro) }
    }

    // MARK: Planned / free runs (per accepted fix)

    /// Everything a non-structured run says, in the order it should be said. Empty while paused
    /// (pace reads are stale and time isn't advancing). `elapsedS` is MOVING time.
    mutating func plannedFix(distanceM: Double, elapsedS: TimeInterval, smoothedPaceSPerKm: Double,
                             paused: Bool, gpsLost: Bool) -> [Line] {
        guard !paused else { return [] }
        var out: [Line] = []
        let goalReachedNow = goalMeters.map { $0 > 0 && !goalAnnounced && distanceM >= $0 } ?? false

        let count = Int(distanceM / unitMeters)
        if count > lastUnitCount {
            let crossed = count - lastUnitCount   // >1 only when one fix jumps a whole unit (a burst)
            lastUnitCount = count
            let splitS = (elapsedS - lastBoundaryElapsedS) / Double(crossed)
            lastBoundaryElapsedS = elapsedS
            // The goal line carries the moment; a split in the same breath would be talked over.
            if !goalReachedNow {
                out.append(Line(text: CoachingCueBuilder.milestone(unitCount: count,
                                                                   splitSecPerUnit: speaksSplitPace ? splitS : 0,
                                                                   unit: unit),
                                priority: .milestone, kind: .split))
            }
        }
        if let goal = goalMeters, goal > 0 {
            if goalReachedNow {
                goalAnnounced = true
                out.append(Line(text: CoachingCueBuilder.goalReached(), priority: .transition, kind: .goal))
            } else if !goalAnnounced, !finalStretchAnnounced, goal >= 3 * unitMeters,
                      goal - distanceM <= unitMeters {
                // "Last mile" only on runs long enough for it to mean something (3+ units).
                finalStretchAnnounced = true
                halfwayAnnounced = true
                out.append(Line(text: CoachingCueBuilder.finalStretch(unit: unit), priority: .milestone, kind: .finalStretch))
            } else if !goalAnnounced, !halfwayAnnounced, goal >= 2 * unitMeters, distanceM >= goal / 2 {
                halfwayAnnounced = true
                out.append(Line(text: CoachingCueBuilder.halfway(remainingMeters: goal - distanceM, unit: unit),
                                priority: .milestone, kind: .halfway))
            }
        }
        if let drift = plannedDrift(elapsedS: elapsedS, pace: smoothedPaceSPerKm, gpsLost: gpsLost) {
            out.append(drift)
        }
        return out
    }

    /// Drift on a plan-paced easy/long run: a wide band (easy days are ranges, not numbers), the
    /// warm-up hold-off, hysteresis at the edge, a hold before the first word and a long cooldown.
    private mutating func plannedDrift(elapsedS now: TimeInterval, pace: Double, gpsLost: Bool) -> Line? {
        guard let target = targetPaceSPerKm, target > 0, !gpsLost,
              now > Self.plannedWarmupHoldS, pace > 0 else { return nil }
        let outer = Self.plannedOuterBandSPerKm, inner = Self.plannedInnerBandSPerKm
        let a: Adherence
        if pace < target - outer { a = .tooFast }
        else if pace > target + outer { a = .tooSlow }
        else if abs(pace - target) < inner { a = .onPace }
        else { a = lastDriftDirection == .onPace ? .onPace : lastDriftDirection }   // hysteresis zone: hold
        if a == .onPace || a == .noTarget {
            driftSince = nil
            lastDriftDirection = .onPace
            return nil
        }
        if a != lastDriftDirection || driftSince == nil { driftSince = now; lastDriftDirection = a }
        guard let since = driftSince, now - since >= Self.driftHoldS,
              now - lastPaceNudgeAt > Self.plannedNudgeCooldownS else { return nil }
        return Line(text: CoachingCueBuilder.paceDrift(a), priority: .ambient, kind: .nudge)
    }

    // MARK: Structured sessions (per 1 Hz tick, inside a step)

    /// A step boundary wipes the drift record. Both fields go, not just the clock: with only
    /// `driftSince` cleared, an athlete still slow into the next rep (same direction as before)
    /// never re-opened a drift window, and that step could not be nudged at all.
    mutating func stepChanged() {
        driftSince = nil
        lastDriftDirection = .noTarget
    }

    /// The in-step word: a nudge once you've drifted outside the band and STAYED there, then a long
    /// cooldown; at most one "on pace" per step, well apart and never on the heels of a correction.
    /// Held off for the first seconds of a step so the smoothed pace has caught up. `now` is the
    /// structured clock (manual pauses only).
    mutating func structuredTick(stepIndex: Int, stepAnchorElapsedS: TimeInterval, adherence a: Adherence,
                                 elapsedS now: TimeInterval, paused: Bool) -> Line? {
        guard !paused, now - stepAnchorElapsedS > Self.stepSettleS else { return nil }
        switch a {
        case .tooFast, .tooSlow:
            if a != lastDriftDirection || driftSince == nil { driftSince = now; lastDriftDirection = a }
            guard let since = driftSince, now - since >= Self.driftHoldS,
                  now - lastPaceNudgeAt > Self.nudgeCooldownS else { return nil }
            return Line(text: CoachingCueBuilder.paceNudge(a), priority: .ambient, kind: .nudge)
        case .onPace:
            driftSince = nil
            lastDriftDirection = .onPace
            guard encouragedStepIndex != stepIndex,
                  now - stepAnchorElapsedS > Self.encouragementAfterS,
                  now - lastEncouragementAt > Self.encouragementSpacingS,
                  now - lastPaceNudgeAt > Self.encouragementAfterNudgeS else { return nil }
            return Line(text: CoachingCueBuilder.encouragement(encouragementCount), priority: .ambient, kind: .encouragement)
        case .noTarget:
            driftSince = nil
            lastDriftDirection = .noTarget
            return nil
        }
    }

    /// Book-keeping for an ambient line that was actually spoken. Cooldowns start only when the
    /// words were heard — a nudge dropped behind a mile split must not silence the coach for the
    /// next two minutes.
    mutating func spoke(_ line: Line, stepIndex: Int?, at now: TimeInterval) {
        switch line.kind {
        case .encouragement:
            encouragementCount += 1
            lastEncouragementAt = now
            if let stepIndex { encouragedStepIndex = stepIndex }
        case .nudge:
            lastPaceNudgeAt = now
        default:
            break
        }
    }
}
