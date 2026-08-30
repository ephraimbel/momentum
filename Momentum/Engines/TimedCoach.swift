import Foundation

/// The coach for sports with no tape: tennis, soccer, basketball, golf, yoga, pilates, the pool,
/// the erg, the stationary bike (`WorkoutType.isTimed`).
///
/// Same contract as `LiveRunCoach` — pure, told the time by its caller, holding only the
/// book-keeping it needs — so a two-hour match replays in a unit test and the exact call sequence
/// is pinnable. There is one beat here, the clock, because the clock is the only thing these sports
/// measure. Getting that right matters more than saying a lot: a yoga class does not want a voice
/// in it every ten minutes, and a rower between pieces does.
struct TimedCoach: Equatable, Sendable {
    typealias Line = CoachCueGate.Line

    /// How often the clock is called, by sport. The quiet rooms get long silences; interval-shaped
    /// work gets a shorter one, because five minutes is a piece.
    static func intervalS(for type: WorkoutType) -> TimeInterval {
        switch type {
        case .yoga, .pilates, .golf: 900        // 15 min: a calm room, called rarely
        case .swimming, .rowing: 300            // 5 min: interval-shaped work
        default: 600                            // 10 min: match sports and everything else
        }
    }

    let type: WorkoutType
    /// Minute of the last call, so a resumed clock picks up where it left off instead of
    /// re-announcing every milestone it already passed.
    private(set) var lastCalledMinute = 0

    init(type: WorkoutType) { self.type = type }

    private var intervalMinutes: Int { max(1, Int(Self.intervalS(for: type) / 60)) }

    /// What is recording. Spoken once, as the stopwatch starts.
    func intro() -> Line {
        Line(text: CoachingCueBuilder.timedIntro(type), priority: .transition, kind: .intro)
    }

    /// The clock, called on its interval. `elapsedS` is ACTIVE time (the paused span is already
    /// out of it), so a match that stops for twenty minutes resumes at the minute it left.
    mutating func tick(elapsedS: TimeInterval, paused: Bool) -> Line? {
        guard !paused, elapsedS > 0 else { return nil }
        let minutes = Int(elapsedS / 60)
        guard minutes >= lastCalledMinute + intervalMinutes else { return nil }
        // Snap to the interval rather than to `minutes`: a tick that lands late (the app was
        // suspended, the ticker slipped) must not drag every later call off the grid with it.
        lastCalledMinute = (minutes / intervalMinutes) * intervalMinutes
        return Line(text: CoachingCueBuilder.timedMilestone(minutes: lastCalledMinute),
                    priority: .milestone, kind: .split)
    }

    /// The closing line: the one number the sport measured.
    func complete(elapsedS: TimeInterval) -> Line {
        Line(text: CoachingCueBuilder.timedComplete(elapsedS: elapsedS),
             priority: .transition, kind: .complete)
    }
}
