import Foundation
import SwiftData

/// Calendar-relative, factual check-ins. They describe observations and invite feedback;
/// only the adaptation engine may claim it changed a workout.
@MainActor
enum WeeklyCoachCheckin {
    struct Note {
        var kind: String
        var title: String
        var body: String
        var expiry: Date
    }

    static func note(completed: Int, planned: Int, day: Int, week: DateInterval,
                     calendar: Calendar) -> Note? {
        guard planned > 0, (3...6).contains(day) else { return nil }
        let progress = "You've completed \(completed) of \(planned) planned runs this week."
        if day >= 5 {
            return Note(kind: "nearly", title: "Help shape your next week",
                body: progress + " Keep your recovery feedback up to date to help your coach decide what comes next. Your next week is finalized when this training week ends.", expiry: week.end)
        }
        let guidance = completed == 0
            ? "If your schedule changed, adjust the remaining days in Plan. There's no need to make up missed mileage."
            : completed >= planned
                ? "Your scheduled runs are complete. Use the remaining days to recover; extra mileage isn't needed to earn progression."
                : "Keep the remaining runs at their prescribed effort. Your training and recovery will guide the next step."
        return Note(kind: "midweek", title: "Your week so far", body: progress + " " + guidance,
                    expiry: calendar.date(byAdding: .day, value: 5, to: week.start) ?? week.end)
    }

    static func sweep(plan: TrainingPlan, now: Date = Date(), in context: ModelContext) {
        guard !plan.isSelfCoached, let state = plan.adaptiveState,
              !state.requiresRecoveryCheckin, IllnessResponse.state(for: plan) == nil else { return }
        let week = AdaptiveTrainingWeek.week(containing: now, calendar: state.calendar)
        guard state.lastWeekStart == week.start,
              state.reviews.last(where: { $0.id == state.lastWeekKey }).map({ $0.viewedAt != nil }) ?? true else { return }
        let initial = state.baseline
        let sessions = plan.sessions.filter { $0.discipline == .running && $0.date >= week.start && $0.date < week.end }
        let planned = initial.isEmpty ? sessions.count : initial.count
        let done = initial.isEmpty ? sessions.filter { $0.status == .completed || $0.completedWorkout != nil }.count
            : initial.filter { before in plan.sessions.contains { $0.id == before.id && ($0.status == .completed || $0.completedWorkout != nil) } }.count
        let day = state.calendar.dateComponents([.day], from: week.start, to: now).day ?? 0
        guard let note = note(completed: done, planned: planned, day: day, week: week, calendar: state.calendar) else { return }
        AppNotification.post(kind: .coaching, title: note.title, body: note.body, on: now, in: context,
            dedupeToken: "weekly-checkin.\(plan.id).\(state.lastWeekKey).\(note.kind)", daily: false,
            route: .plan, coachingPriority: 40, expiresAt: note.expiry, topic: "weekly-progress.\(plan.id)")
    }
}
