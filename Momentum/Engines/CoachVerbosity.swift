import Foundation

/// How much the voice coach says. Strava's dial, because every runner already knows it: the words
/// that change the workout are always spoken; the numbers are what you turn up or down.
///
/// The screen is not on this dial. Every line still lands on the live screen at every level; the
/// dial decides which of them are also read into your ear. A split you can glance at costs nothing;
/// a split read aloud on a recovery jog costs the recovery. The filter sits in ONE place, the
/// voice's `announce(_:kind:)`, so the run, the stopwatch sports, the gym and the wrist all obey it
/// without knowing it exists.
enum CoachVerbosity: String, CaseIterable, Sendable, Equatable {
    /// Transitions only: what the session is, each step as it changes, the goal, the finish, and
    /// your own pauses. A race, a quiet long run, a class you want to hear the teacher in.
    case minimal
    /// The coach as shipped: + every split, halfway and the last unit, the pace nudges, the one
    /// "on pace" per step, and the ten-second call before a timed step ends.
    case standard
    /// + the heart-rate zone on every split while a monitor is live.
    case full

    static let `default`: CoachVerbosity = .standard

    var title: String {
        switch self {
        case .minimal: "Minimal"
        case .standard: "Standard"
        case .full: "Full"
        }
    }

    /// What this level promises, for the Settings row.
    var blurb: String {
        switch self {
        case .minimal: "Step changes, goal and finish only"
        case .standard: "Splits, step changes and pace cues"
        case .full: "Everything, plus your heart-rate zone on each split"
        }
    }

    /// Whether a line of this kind is SPOKEN at this level. `.other` is spoken at every level: it is
    /// the kind of the ad-hoc transitions (pause, resume, the gym's rests), which are never noise.
    func speaks(_ kind: CoachCueGate.Line.Kind) -> Bool {
        switch kind {
        case .intro, .stepStart, .goal, .complete, .other:
            true
        case .split, .halfway, .finalStretch, .nudge, .encouragement, .stepWarning:
            self != .minimal
        }
    }

    /// Whether a split carries its heart-rate zone at this level.
    var speaksZone: Bool { self == .full }
}
