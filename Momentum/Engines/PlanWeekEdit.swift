import Foundation

/// Week-shaped edits to a training week.
///
/// Travel and illness do not arrive one session at a time, but until now the Plan board only knew
/// how to move one session at a time: a Thursday-to-Sunday trip cost five separate drags. These are
/// the two edits that are genuinely week-shaped — slide the whole week a day, and take some days
/// out of it — expressed as pure placement decisions so they are testable and so the board and any
/// future surface can never disagree about where the work lands.
///
/// Nothing here deletes a session or changes what it asks for. Sessions move; the week's work is
/// preserved or it is left where it was and the caller says so plainly. No-shame throughout.
enum PlanWeekEdit {

    /// Where each session on a blocked day should go.
    ///
    /// - Parameters:
    ///   - sessions: every movable session in the week as `(id, dayIndex)`, `dayIndex` 0...6 from
    ///     the week's first day. Days may repeat — a day can hold several sessions.
    ///   - blocked: the day indices the athlete is away.
    /// - Returns: `id -> new dayIndex`, containing only the sessions that actually move. A session
    ///   with nowhere to go is absent rather than stacked onto an already-busy day: doubling up a
    ///   week the athlete is already losing days from is how a "helpful" reshuffle becomes an
    ///   injury. The caller reports what it could not place.
    static func awayPlacements(sessions: [(id: UUID, dayIndex: Int)],
                               blocked: Set<Int>) -> [UUID: Int] {
        var occupied = Set(sessions.map(\.dayIndex))
        var out: [UUID: Int] = [:]
        // Earliest first, so a Thursday session gets first claim on Friday and the Saturday one
        // does not leapfrog it. Deterministic regardless of the order sessions arrive in.
        for session in sessions.filter({ blocked.contains($0.dayIndex) })
            .sorted(by: { ($0.dayIndex, $0.id.uuidString) < ($1.dayIndex, $1.id.uuidString) }) {
            guard let target = nearestOpenDay(from: session.dayIndex,
                                              blocked: blocked, occupied: occupied) else { continue }
            out[session.id] = target
            occupied.insert(target)
        }
        return out
    }

    /// The closest free day in the week, ties going forward.
    ///
    /// NEAREST, not "always after the trip": a session wants to stay near the slot the plan chose
    /// for it, and pushing every displaced day past the absence clusters the week's work into
    /// whatever days are left over. Closest-first preserves the spacing the plan was built with.
    /// When two days are equally close, the one AFTER the away stretch wins — that is the natural
    /// home for work you were out for.
    private static func nearestOpenDay(from day: Int, blocked: Set<Int>, occupied: Set<Int>) -> Int? {
        for distance in 1...6 {
            for candidate in [day + distance, day - distance] {
                guard (0...6).contains(candidate),
                      !blocked.contains(candidate),
                      !occupied.contains(candidate) else { continue }
                return candidate
            }
        }
        return nil
    }
}
