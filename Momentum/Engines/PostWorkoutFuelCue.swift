import Foundation

/// The post-workout refuel cue (fuel integration 2026-09-06): after a long run or an exerting
/// session, one nudge toward carbs and protein in the recovery window. Deterministic and pure,
/// like every engine here, and deliberately UNSPECIFIC: it never names an amount, a food, or a
/// macro target. What and how much is the athlete's call and their goals' business (fueling, not
/// dieting). The words point at Fuel, where they log whatever they chose.
///
/// "Exerting" is decided from the session itself, never from calories:
///  • a planned long run or a race, whatever the clock said;
///  • an hour or more of any cardio (run, ride, swim, row, a timed sport);
///  • a quality run (steady, repeats, hills, fartlek, progression) or any cardio the athlete
///    rated hard (RPE 7+), once it is a real session (30 min+);
///  • a lift of 40 min+ or 12+ completed working sets;
///  • a walk or hike of 90 min+.
/// An easy 30 minute jog earns nothing; the nudge is for the sessions that empty the tank.
enum PostWorkoutFuelCue {

    enum Emphasis: String, Equatable, Sendable, CaseIterable {
        case longRun, race, hardSession, lift, longEffort
    }

    struct Cue: Equatable, Sendable {
        let emphasis: Emphasis
        let title: String
        let body: String
    }

    static let longCardioS: Double = 60 * 60
    static let qualityMinS: Double = 30 * 60
    static let liftMinS: Double = 40 * 60
    static let liftMinWorkingSets = 12
    static let walkMinS: Double = 90 * 60
    static let hardRPE = 7
    /// The cue lands 25 minutes after the finish: past the cool-down and the shower, still inside
    /// the hour the words talk about.
    static let delayS: Double = 25 * 60
    /// A workout logged long after it ended has no window left to talk about.
    static let staleAfterS: Double = 90 * 60

    /// The decision, from the session's own facts.
    static func emphasis(type: WorkoutType, durationS: Double, rpe: Int?, runType: RunType?,
                         workingSets: Int) -> Emphasis? {
        if type.isStrengthStyle {
            return (durationS >= liftMinS || workingSets >= liftMinWorkingSets) ? .lift : nil
        }
        if runType == .race { return .race }
        if runType == .long { return .longRun }
        let hard = (rpe ?? 0) >= hardRPE
        switch type {
        case .run, .trailRun:
            if durationS >= longCardioS { return .longEffort }
            if durationS >= qualityMinS, hard || isQuality(runType) { return .hardSession }
            return nil
        case .walk, .hike:
            return durationS >= walkMinS ? .longEffort : nil
        default:
            if durationS >= longCardioS { return .longEffort }
            if durationS >= qualityMinS, hard { return .hardSession }
            return nil
        }
    }

    static func isQuality(_ runType: RunType?) -> Bool {
        switch runType {
        case .tempo, .intervals, .hills, .fartlek, .progression: true
        default: false
        }
    }

    /// The words. Plain sentences, no numbers, no foods, no dashes; the athlete decides the rest.
    static func words(_ emphasis: Emphasis, noun: String) -> (title: String, body: String) {
        switch emphasis {
        case .longRun:
            ("Refuel after your long run",
             "Some carbs and protein in the next hour help you recover. What and how much is your call. Log it in Fuel when you eat.")
        case .race:
            ("Refuel after the race",
             "Carbs and protein soon help the recovery start. What and how much is your call. Log it in Fuel when you eat.")
        case .hardSession:
            ("Refuel after that session",
             "Some carbs and protein in the next hour help you absorb the work. What and how much is your call. Log it in Fuel when you eat.")
        case .lift:
            ("Protein after your lift",
             "Some protein and carbs in the next hour help the rebuild. What and how much is your call. Log it in Fuel when you eat.")
        case .longEffort:
            ("Refuel after that \(noun)",
             "Some carbs and protein in the next hour help you recover. What and how much is your call. Log it in Fuel when you eat.")
        }
    }

    /// The sport word for the generic emphasis: "run", "ride", "walk", else "session".
    static func noun(for type: WorkoutType) -> String {
        switch type.discipline {
        case .running: type == .run || type == .trailRun ? "run" : "session"
        case .cycling: "ride"
        case .walking: "walk"
        case .strength: "session"
        }
    }

    /// The full cue for a saved workout, or nil when the session was not exerting.
    @MainActor
    static func cue(for workout: Workout) -> Cue? {
        let workingSets = workout.strength?.exercises
            .flatMap(\.sets)
            .filter { $0.type == .working && $0.isComplete }
            .count ?? 0
        guard let emphasis = emphasis(type: workout.type, durationS: workout.durationS,
                                      rpe: workout.perceivedEffort,
                                      runType: workout.plannedSession?.runType,
                                      workingSets: workingSets) else { return nil }
        let w = words(emphasis, noun: noun(for: workout.type))
        return Cue(emphasis: emphasis, title: w.title, body: w.body)
    }

    #if DEBUG
    /// `--refuel-fire` shortens the lead to seconds, so a UI test can tap the REAL banner the
    /// production path schedules. DEBUG-only; nil in every other run.
    nonisolated(unsafe) static var debugLead: (delay: Double, floor: Double)?
    #endif

    /// When the cue fires: 25 minutes after the finish, never sooner than a minute from now, and
    /// not at all once the finish is more than 90 minutes behind us (a workout logged after the
    /// fact has no window left).
    static func fireDate(endedAt: Date, now: Date) -> Date? {
        guard now.timeIntervalSince(endedAt) < staleAfterS else { return nil }
        var delay = delayS, floor = 60.0
        #if DEBUG
        if let lead = debugLead { delay = lead.delay; floor = lead.floor }
        #endif
        return max(now.addingTimeInterval(floor), endedAt.addingTimeInterval(delay))
    }
}
