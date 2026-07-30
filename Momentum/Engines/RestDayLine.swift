import Foundation

/// The one quiet line a rest day earns on the Plan board.
///
/// Four or five rows of a normal training week used to read "Rest day" and nothing else — half
/// the surface that represents the athlete's week carrying zero information. But a prescribed
/// rest day is never arbitrary: it sits where it does because of what's around it, and saying so
/// is the cheapest coaching the board can do. Rest is also the prescription athletes override
/// most readily; a reason attached is the difference between "empty day" and "part of the plan".
///
/// Deterministic rules over the day's neighbours, in strict priority order — the future outranks
/// the past (preparation is more actionable than absorption), and the biggest sessions outrank
/// the rest. Returns nil when no rule fires; the board falls back to the plain "Rest day", because
/// a manufactured reason on every row would read as filler and devalue the real ones.
///
/// No-shame throughout: these lines explain placement, they never audit the athlete.
enum RestDayLine {

    /// What kind of work a neighbouring day holds, reduced to what placement logic cares about.
    enum Neighbor: Sendable, Equatable {
        case race
        case long
        case quality      // intervals, tempo, hills, fartlek — the hard running
        case strength
        case easy
        case none
    }

    /// The line for a rest day, or nil for the plain default.
    /// - Parameters:
    ///   - yesterday/tomorrow/dayAfter: the strongest session on each neighbouring day
    ///     (`strongest(_:)` picks it when a day holds several).
    ///   - phase: the displayed week's macrocycle phase, for the taper/recovery fallbacks.
    static func line(yesterday: Neighbor, tomorrow: Neighbor, dayAfter: Neighbor,
                     phase: PlanPhase?) -> String? {
        // Tomorrow first: what a rest day is FOR beats what it follows.
        switch tomorrow {
        case .race: return "Rest — everything banked for race day."
        case .long: return "Rest — fresh legs for tomorrow's long run."
        case .quality: return "Rest — fresh for tomorrow's speed work."
        case .strength, .easy, .none: break
        }
        switch yesterday {
        case .race: return "Rest — you earned this one."
        case .long: return "Rest — absorbing yesterday's long run."
        case .quality: return "Rest — absorbing yesterday's hard work."
        case .strength, .easy, .none: break
        }
        if dayAfter == .long { return "Rest — two days out from the long run." }
        if dayAfter == .race { return "Rest — two days out from the race." }
        switch phase {
        case .taper: return "Rest — the taper is doing its work."
        case .recovery: return "Rest — down week, lighter on purpose."
        default: return nil
        }
    }

    /// The day's strongest claim when it holds several sessions (a long run beside a lift is a
    /// long-run day as far as the rest around it is concerned).
    static func strongest(_ neighbors: [Neighbor]) -> Neighbor {
        for want: Neighbor in [.race, .long, .quality, .strength, .easy] where neighbors.contains(want) {
            return want
        }
        return .none
    }
}
