import Foundation
import SwiftData

/// Plan queries + deterministic, no-shame adaptation (PRD §4.7, §9.4). Missed sessions **move**;
/// there is never a red "failed" state.
@MainActor
enum PlanCoaching {

    static func todaySessions(_ plan: TrainingPlan?, on date: Date, calendar: Calendar = .current) -> [PlannedSession] {
        guard let plan else { return [] }
        let day = calendar.startOfDay(for: date)
        return plan.sessions
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
    }

    static func weekSessions(_ plan: TrainingPlan?, containing date: Date, calendar: Calendar = .current) -> [PlannedSession] {
        guard let plan, let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return plan.sessions
            .filter { interval.contains($0.date) }
            .sorted { $0.date < $1.date }
    }

    /// Link a finished workout to its planned session.
    static func markComplete(_ session: PlannedSession, with workout: Workout, in context: ModelContext) {
        session.completedWorkout = workout
        session.status = .completed
        workout.plannedSession = session
        try? context.save()
    }

    /// Credit a free workout toward today's matching planned session, if still open.
    @discardableResult
    static func creditWorkout(_ workout: Workout, to plan: TrainingPlan?, in context: ModelContext,
                              calendar: Calendar = .current) -> PlannedSession? {
        guard let plan else { return nil }
        let candidates = todaySessions(plan, on: workout.startedAt, calendar: calendar)
        guard let match = candidates.first(where: {
            $0.status == .planned && $0.completedWorkout == nil && $0.discipline == workout.type.discipline
        }) else { return nil }
        markComplete(match, with: workout, in: context)
        return match
    }

    /// Move past, still-planned sessions onto the next open day — never a red miss (§9.4).
    static func reconcileMissed(_ plan: TrainingPlan?, today: Date, in context: ModelContext,
                                calendar: Calendar = .current) {
        guard let plan else { return }
        let todayStart = calendar.startOfDay(for: today)
        var occupied = Set(plan.sessions.map { calendar.startOfDay(for: $0.date) })
        var changed = false

        for session in plan.sessions
            where session.status == .planned
            && session.completedWorkout == nil
            && calendar.startOfDay(for: session.date) < todayStart {

            var moved = false
            for delta in 0..<7 {
                guard let cand = calendar.date(byAdding: .day, value: delta, to: todayStart) else { continue }
                if !occupied.contains(cand) {
                    occupied.remove(calendar.startOfDay(for: session.date))
                    session.date = cand
                    session.status = .moved
                    session.rationale = "Shifted to \(cand.formatted(.dateTime.weekday(.wide))) — still on track."
                    occupied.insert(cand)
                    moved = true
                    changed = true
                    break
                }
            }
            if !moved {
                session.status = .moved
                session.rationale = "Rolled forward — no streak lost."
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    /// Human pre-session brief (PRD §4.7), deterministic; the AI may rewrite it later.
    static func brief(for session: PlannedSession, distanceUnit: DistanceUnit = .auto) -> String {
        if session.discipline == .strength {
            let label = session.strengthTargets.count >= 5 ? "Full body" : "Strength"
            return "\(label) — \(session.strengthTargets.count) exercises"
        }
        let type = session.runType?.rawValue.capitalized ?? "Session"
        let dist = session.targetDistanceM.map { Formatters.distance(meters: $0, unit: distanceUnit) } ?? ""
        if let pace = session.targetPaceSPerKm, pace > 0 {
            return "\(type) \(dist) ~\(Formatters.pace(secPerKm: pace, unit: distanceUnit))"
        }
        return "\(type) \(dist)"
    }
}
