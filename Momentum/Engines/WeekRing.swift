import Foundation
import SwiftData

/// What the post-workout celebration ring actually measures: the athlete's running week, and the
/// piece of it the session just finished has added.
///
/// The ring used to sweep to full on every workout regardless of what happened — a spinner wearing
/// an achievement's clothes, in an app whose whole accent rule is that iridescence marks progress.
///
/// The obvious fix — filling it to how much of the PRESCRIBED session was completed — is wrong, and
/// worth spelling out so nobody re-introduces it: a run cut short would land the ring at 60% and put
/// a visible failure state at the emotional peak of the app, which is exactly what the no-shame rule
/// forbids. A week can only ever go up. Finishing anything adds to it, so the sweep is always a gain,
/// and a partly-filled ring reads as "mid-week", never as "you fell short".
///
/// Pure by design (no SwiftData, no `Date()`) so every branch is fixture-testable.
enum WeekRing {

    struct Reading: Sendable, Equatable {
        /// Where the ring starts — the week BEFORE this session landed. 0…1.
        let from: Double
        /// Where it sweeps to — the week including it. 0…1. Never less than `from`.
        let to: Double
        /// Metres completed this week, this session included. Un-clamped, for the caption.
        let completedM: Double
        /// The week's target in metres.
        let targetM: Double

        /// This session is the one that took the week over its target — an earned moment, and the
        /// only place the celebration is entitled to say so.
        var closedTheWeek: Bool { to >= 1 && from < 1 }
    }

    /// - Parameters:
    ///   - justFinishedM: distance of the session that just ended.
    ///   - earlierThisWeekM: distance already logged this week, EXCLUDING that session.
    ///   - targetM: the week's target — a plan's prescribed volume, else the athlete's own figure.
    /// - Returns: nil when there's nothing honest to draw: no target to measure against, or a
    ///   session that added no distance (a treadmill run with no GPS lock has nothing to contribute).
    static func reading(justFinishedM: Double, earlierThisWeekM: Double, targetM: Double) -> Reading? {
        guard targetM > 0, justFinishedM > 0 else { return nil }
        let earlier = max(0, earlierThisWeekM)
        let completed = earlier + justFinishedM
        return Reading(from: min(1, earlier / targetM),
                       to: min(1, completed / targetM),
                       completedM: completed,
                       targetM: targetM)
    }
}

/// Reads the store for what `WeekRing` needs. Kept apart from the arithmetic above so the rules stay
/// pure and fixture-testable, and shared by every caller so the debug harness exercises the same path
/// the finish flow does rather than a lookalike.
@MainActor
enum WeekRingReader {

    /// - Note: runs on the synchronous finish path, so the week is scoped by predicate rather than
    ///   filtered out of a full fetch — faulting the whole workout table there is the exact stall the
    ///   adaptive pass was moved off this path to avoid.
    static func reading(for workout: Workout, plan: TrainingPlan?, profile: UserProfile?,
                        in context: ModelContext, calendar: Calendar = .current) -> WeekRing.Reading? {
        guard workout.type.discipline == .running, let distance = workout.gps?.distanceM, distance > 0
        else { return nil }
        guard let week = calendar.dateInterval(of: .weekOfYear, for: workout.startedAt) else { return nil }

        let (start, end, id) = (week.start, week.end, workout.id)
        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end && $0.id != id })
        let earlier = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.type.discipline == .running }
            .compactMap { $0.gps?.distanceM }
            .reduce(0, +)

        return WeekRing.reading(justFinishedM: distance, earlierThisWeekM: earlier,
                                targetM: targetM(plan: plan, profile: profile, week: week))
    }

    /// The week's running target: what the plan actually prescribes, else the athlete's own declared
    /// weekly volume. Zero from both means there's nothing honest to measure against, and `WeekRing`
    /// returns nil rather than inventing a denominator.
    private static func targetM(plan: TrainingPlan?, profile: UserProfile?, week: DateInterval) -> Double {
        let prescribed = (plan?.sessions ?? [])
            .filter { $0.discipline == .running && week.contains($0.date) }
            .compactMap(\.targetDistanceM)
            .reduce(0, +)
        return prescribed > 0 ? prescribed : (profile?.weeklyRunVolumeM ?? 0)
    }
}
