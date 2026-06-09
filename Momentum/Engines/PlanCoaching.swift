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

    /// Apply the Progress coach's recommendation to **future** planned sessions (PRD §4.7, §9).
    /// Adjusts only sessions dated today-or-later and still `.planned` — completed work and history
    /// are never touched. Deterministic: rules reshape the plan, the coach only narrates it.
    /// Returns the number of sessions changed (0 ⇒ nothing upcoming, or an advisory-only rec).
    ///
    /// Note: the recommendation is derived from *completed* load, not from the plan, so applying
    /// the same rec repeatedly compounds. The UI confirms once and disables re-tapping per render.
    @discardableResult
    static func apply(_ rec: ProgressInsights.Recommendation, to plan: TrainingPlan?,
                      from date: Date = Date(), in context: ModelContext,
                      calendar: Calendar = .current) -> Int {
        guard let plan else { return 0 }
        let todayStart = calendar.startOfDay(for: date)
        let future = plan.sessions
            .filter { $0.status == .planned && $0.completedWorkout == nil
                      && calendar.startOfDay(for: $0.date) >= todayStart }
            .sorted { $0.date < $1.date }
        guard !future.isEmpty else { return 0 }
        let p5k = plan.p5kSPerKm

        // Scale a cardio session's targets and soften any hard quality work to easy.
        func soften(_ s: PlannedSession, factor: Double, note: String) {
            if let d = s.targetDistanceM { s.targetDistanceM = (d * factor).rounded() }
            if let dur = s.targetDurationS { s.targetDurationS = (dur * factor).rounded() }
            if s.runType == .intervals || s.runType == .tempo || s.runType == .long {
                s.runType = .easy
                s.intervals = nil
                s.targetPaceSPerKm = PlanEngine.pace(.easy, p5k: p5k)
            }
            s.rationale = note
        }

        switch rec {
        case .increase:
            for s in future {
                if let d = s.targetDistanceM { s.targetDistanceM = (d * 1.1).rounded() }
                if let dur = s.targetDurationS { s.targetDurationS = (dur * 1.1).rounded() }
                for pe in s.strengthTargets { pe.targetSets = min(6, pe.targetSets + 1) }
                s.rationale = "Nudged up ~10% — your load says you've earned more."
            }
        case .ease:
            for s in future {
                soften(s, factor: 0.85, note: "Eased ~15% to absorb your recent load.")
                for pe in s.strengthTargets { pe.targetSets = max(2, pe.targetSets - 1) }
            }
        case .rest:
            for s in future {
                soften(s, factor: 0.8, note: "Pulled back to bank recovery.")
                for pe in s.strengthTargets { pe.targetSets = max(2, pe.targetSets - 1) }
            }
            // Make the very next session a true recovery day.
            let next = future[0]
            if next.strengthTargets.isEmpty {
                next.runType = .recovery
                next.intervals = nil
                next.targetDistanceM = min(next.targetDistanceM ?? 3200, 3200)
                next.targetPaceSPerKm = PlanEngine.pace(.recovery, p5k: p5k)
            } else {
                for pe in next.strengthTargets { pe.targetSets = 2 }
            }
            next.rationale = "Recovery day — rest is where the gains land."
        case .hold, .start:
            return 0   // advisory only — nothing to change
        }
        try? context.save()
        return future.count
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
