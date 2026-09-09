#if DEBUG
import Foundation
import SwiftData

/// Simulator fixture uses production persistence, selection, display tracking and routing.
@MainActor
enum CoachLoopDemo {
    static func seedReview(in context: ModelContext) {
        guard let p = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first,
              let plan = p.plan else { return }
        AdaptivePlanService.initialize(plan, profileID: p.id, now: Date(), in: context)
        guard let state = plan.adaptiveState else { return }
        let previous = state.calendar.date(byAdding: .day, value: -7, to: state.lastWeekStart)!
        state.lastWeekStart = previous
        state.lastWeekKey = AdaptiveTrainingWeek.key(previous, calendar: state.calendar)
        state.baseline = plan.sessions.filter { $0.date >= previous && $0.date < state.calendar.date(byAdding: .day, value: 7, to: previous)! && $0.discipline == .running }
            .map { .init(id: $0.id, date: $0.date, distanceM: $0.targetDistanceM ?? 0) }
        try? context.save()
        AdaptivePlanService.refresh(profile: p, in: context)
    }

    static func seed(in context: ModelContext) {
        NotificationPrefs.set(NotificationPrefs.coachingKey, to: true)
        let existing = (try? context.fetch(FetchDescriptor<CoachMessageReceipt>())) ?? []
        for r in existing { r.expiresAt = .distantPast }
        try? context.save()
        AppNotification.post(kind: .coaching, title: "Your week so far", body: "A lower priority weekly observation.",
            in: context, dedupeToken: "coach-loop-demo-low", daily: false, route: .plan, coachingPriority: 40)
        AppNotification.post(kind: .coaching, title: "Recovery check-in ready", body: "Open Plan to review the recovery guidance before your next planned run.",
            in: context, dedupeToken: "coach-loop-demo-high", daily: false, route: .plan, coachingPriority: 100)
    }
}
#endif
