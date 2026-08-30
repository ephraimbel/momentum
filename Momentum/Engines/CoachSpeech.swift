import Foundation

/// How a sport talks.
///
/// `LiveRunCoach` and `TimedCoach` decide WHEN the coach speaks. This decides what the words are.
/// The judgement barely changes between sports (a unit is done, you are off target, the goal is
/// close); the vocabulary changes completely. A ride called in minutes per mile is nonsense, a
/// tennis match has no split at all, and a bench press has neither.
///
/// One value per *register*, not one per `WorkoutType`: twenty sports, five ways of speaking.
enum CoachSpeech: String, Sendable, Equatable, CaseIterable {
    /// Pace sports on GPS — run, trail run, and the ball sports that are really running.
    case run
    /// On foot, not running. Same shape as `run`; a walk or a hike is still measured in pace, and
    /// the coach stays quieter because there is no target to chase.
    case walk
    /// Bikes. A completed mile is called with the SPEED that produced it, because that is the
    /// number on every bike computer ever made.
    case ride
    /// Anything on a stopwatch (tennis, yoga, the pool, the erg). No distance, so the clock is the
    /// only milestone there is.
    case timed
    /// The gym. Sets and rests; never a split.
    case strength

    /// The register follows the CAPTURE mode, not the sport's family. That ordering matters for
    /// exactly one case and it is a real one: "E-Bike Ride" means a STATIONARY bike here
    /// (`WorkoutType.isTimed`), so it is coached on the clock like the rest of the stopwatch
    /// sports. Asking `isCycling` first would have promised it splits it can never measure.
    static func forType(_ type: WorkoutType) -> CoachSpeech {
        if type.isStrengthStyle { return .strength }
        if type.isTimed { return .timed }
        if type.isCycling { return .ride }
        switch type {
        case .walk, .hike: return .walk
        default: return .run
        }
    }

    /// True when a completed unit is called with a speed figure rather than a pace figure.
    var splitsInSpeed: Bool { self == .ride }

    /// The word for the number the athlete is holding — "pace" on foot, "speed" on a bike.
    var effortNoun: String { splitsInSpeed ? "speed" : "pace" }

    /// True for the registers that measure ground covered. `timed` and `strength` never do, so the
    /// distance beats (splits, halfway, last mile, goal) are not theirs to speak.
    var callsDistance: Bool {
        switch self {
        case .run, .walk, .ride: true
        case .timed, .strength: false
        }
    }
}
