import Foundation

/// The one honest line a *just-moved* session earns on the Plan board.
///
/// Dragging a session to a new day is the athlete taking the pen, and the coach's job at that
/// moment is not to argue but to say what the new spot actually is: the long run is the next day,
/// this now follows a hard day, two hard sessions share a date. Placement is the whole content of
/// the note. There is no verdict, no "you should", no red state, and nothing is ever blocked.
///
/// Deterministic rules over the landing day's neighbours, strict priority order, reusing
/// `RestDayLine.Neighbor` as the classification so the board's two placement engines can never
/// disagree about what counts as a hard day. Returns nil whenever the move needs no comment, which
/// is most moves. A note on every drop would read as nagging and devalue the ones that matter.
///
/// The result is deliberately **transient** — the Plan board shows it beside the session the athlete
/// just moved and forgets it. It is never persisted onto `rationale`: the sentence is true about a
/// week that the next drag can change, and a stale "your long run is the next day" pinned under a
/// session would be exactly the kind of dishonest artifact the plan surfaces exist to avoid.
enum PlanMoveAdvice {

    typealias Kind = RestDayLine.Neighbor

    /// Hard running — the sessions whose spacing is worth a word.
    private static func isHard(_ kind: Kind) -> Bool {
        switch kind {
        case .race, .long, .quality: true
        case .strength, .easy, .none: false
        }
    }

    /// The line for a session that just landed on a new day, or nil when the placement is ordinary.
    ///
    /// - Parameters:
    ///   - moved: what kind of session was moved.
    ///   - sameDay: the strongest session already on the landing day (`RestDayLine.strongest`),
    ///     excluding the moved one. `.none` when it lands on an open day.
    ///   - dayBefore/dayAfter: the strongest session on each neighbouring day.
    static func note(moved: Kind, sameDay: Kind, dayBefore: Kind, dayAfter: Kind) -> String? {
        // Only hard running earns a note. An easy run or a lift can go wherever it fits, and a
        // race is a fixed point on the calendar — moving one is a decision about the season, not
        // about spacing, so the board stays quiet rather than commenting on it.
        guard moved == .quality || moved == .long else { return nil }

        // Doubling up outranks everything: it is the one placement the athlete most likely
        // did not intend, because the board stacks same-day sessions rather than refusing them.
        if isHard(sameDay) { return "Two hard sessions on the same day." }

        // Race day is the fixed point the rest of the week is arranged around, so its neighbours
        // are named before ordinary hard days are.
        if dayAfter == .race { return "The day before your race." }
        if dayBefore == .race { return "The day after your race." }

        if isHard(dayBefore) && isHard(dayAfter) { return "Hard days on both sides of this one." }

        // Forward before backward, matching RestDayLine: what a day leads into is more actionable
        // than what it followed.
        if dayAfter == .long { return "Your long run is the next day." }
        if dayAfter == .quality { return "Another hard day follows this one." }
        if dayBefore == .long { return "This follows your long run." }
        if dayBefore == .quality { return "This follows a hard day." }

        return nil
    }
}
