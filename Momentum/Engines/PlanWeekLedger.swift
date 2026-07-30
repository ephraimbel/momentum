import Foundation

/// The Plan board's numbers made honest: **planned vs. actually done**, per week.
///
/// The board header used to say "13.23 mi planned" and count checked-off sessions — prescription
/// and attendance, never execution. What a runner actually asks of a week, mid-week or months
/// later, is "how much of it did I run?" — the one habit every serious coaching platform is built
/// around and no consumer app surfaces cleanly. This computes it from numbers the app already
/// stores: session targets on one side, the week's real recorded mileage on the other.
///
/// It also buckets planned volume by week for the masthead's micro-arc — the block's whole shape
/// (build, cutback, peak, taper) in one glance, which is the structure `PlanEngine` designs and
/// the page never showed.
///
/// Pure and calendar-explicit, like the other engines; no SwiftData, every branch fixture-testable.
enum PlanWeekLedger {

    /// A planned session reduced to what the ledger needs.
    struct Session: Sendable, Equatable {
        let targetDistanceM: Double?
        let completed: Bool

        init(targetDistanceM: Double?, completed: Bool) {
            self.targetDistanceM = targetDistanceM
            self.completed = completed
        }
    }

    /// One week's planned-vs-done story.
    struct Ledger: Sendable, Equatable {
        let plannedM: Double
        let doneM: Double
        let doneSessions: Int
        let totalSessions: Int

        /// The progress bar's fill, 0…1.
        ///
        /// Volume-first: a week with distance targets fills by miles banked, because two of four
        /// sessions done is not "half the week" when the two remaining are the long run and the
        /// quality day. Two overrides keep it honest and shame-free:
        /// - **A fully checked week reads full**, even with less mileage recorded than planned —
        ///   an athlete who marked everything done manually (treadmill, imported, untracked) must
        ///   never see a bar that quietly disputes them.
        /// - **Weeks with no distance targets** (strength blocks) fall back to the session count,
        ///   which is all "done" can mean there.
        var fraction: Double {
            if totalSessions > 0, doneSessions >= totalSessions { return 1 }
            if plannedM > 0 { return min(1, doneM / plannedM) }
            guard totalSessions > 0 else { return 0 }
            return Double(doneSessions) / Double(totalSessions)
        }
    }

    /// The displayed week's ledger. `actualCardioM` is the week's real recorded GPS mileage —
    /// every run, planned or not, because unplanned miles are still miles the body ran.
    static func ledger(sessions: [Session], actualCardioM: Double) -> Ledger {
        Ledger(plannedM: sessions.compactMap(\.targetDistanceM).reduce(0, +),
               doneM: max(0, actualCardioM),
               doneSessions: sessions.filter(\.completed).count,
               totalSessions: sessions.count)
    }

    /// Planned distance metres bucketed per plan week — the micro-arc's data.
    ///
    /// Sessions are keyed by their own week-of-year start and matched against `weekStarts`, so a
    /// session dated before the block (carried history) or after its last week simply doesn't
    /// land anywhere — the same rule the strip itself uses, and the reason the arc can never grow
    /// a phantom leading bar.
    static func plannedMetersByWeek(sessions: [(date: Date, targetDistanceM: Double?)],
                                    weekStarts: [Date],
                                    calendar: Calendar = .current) -> [Double] {
        guard !weekStarts.isEmpty else { return [] }
        var indexByWeek: [Date: Int] = [:]
        for (i, start) in weekStarts.enumerated() { indexByWeek[start] = i }
        var out = Array(repeating: 0.0, count: weekStarts.count)
        for s in sessions {
            guard let meters = s.targetDistanceM, meters > 0,
                  let week = calendar.dateInterval(of: .weekOfYear, for: s.date)?.start,
                  let i = indexByWeek[week] else { continue }
            out[i] += meters
        }
        return out
    }
}
