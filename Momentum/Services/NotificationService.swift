import Foundation
import UserNotifications

/// Local notifications (PRD §24) — the "updates" half of the adaptive coach. Two kinds:
///  • **Next-workout reminders** on session days, one per upcoming planned session. The body is the
///    deterministic `PlanCoaching.brief`, so a reminder always carries the *current* prescription —
///    including paces the coach has recalibrated (P1). This is how plan changes reach the next workout.
///  • **"Plan updated" nudges** — an immediate, encouraging note when the coach adapts (e.g. faster
///    paces after a strong run). Shown even in the foreground.
/// No remote push; everything is local and reconstructable from the plan.
@MainActor
final class NotificationService: NSObject, NotificationServing, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let sessionPrefix = "momentum.session."
    private let reminderHour = 7
    private let reminderMinute = 30

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        // Re-acquire the (non-Sendable) center inside the closure rather than capturing it.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    /// Resync per-session reminders to the plan's upcoming sessions (next 7 days). Replaces every
    /// previously scheduled momentum reminder, so moved/recalibrated/deleted sessions stay correct.
    func schedulePlannedReminders(_ plan: TrainingPlan?) {
        requestAuthorization()
        let payloads = plan.map { Self.reminderPayloads(for: $0, hour: reminderHour, minute: reminderMinute) } ?? []
        let prefix = sessionPrefix
        UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
            let center = UNUserNotificationCenter.current()
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            for p in payloads {
                let content = UNMutableNotificationContent()
                content.title = p.title
                content.body = p.body
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: p.fireComponents, repeats: false)
                center.add(UNNotificationRequest(identifier: p.id, content: content, trigger: trigger))
            }
        }
    }

    /// An immediate, encouraging nudge when the coach adapts the plan. A short delay lets it land
    /// just after the post-workout celebration rather than on top of it.
    func notifyPlanUpdated(title: String, body: String) {
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        center.add(UNNotificationRequest(identifier: "momentum.update.\(UUID().uuidString)",
                                         content: content, trigger: trigger))
    }

    // MARK: Rest-timer completion (PRD §24) — static so it schedules to the shared notification
    // center without a second delegate; called by the strength session as rest starts/changes/ends.

    static let restID = "momentum.rest"

    static func scheduleRestTimer(endsAt: Date, exerciseName: String, now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [restID])
        let interval = endsAt.timeIntervalSince(now)
        guard interval > 0.5 else { return }   // already over — nothing to fire
        let content = UNMutableNotificationContent()
        content.title = "Rest's up"
        content.body = exerciseName.isEmpty || exerciseName == "Rest"
            ? "Time for your next set." : "Time for your next \(exerciseName) set."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: restID, content: content, trigger: trigger))
    }

    static func cancelRestTimer() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [restID])
        center.removeDeliveredNotifications(withIdentifiers: [restID])
    }

    // MARK: Sunday check-in (PRD §24) — a weekly recap nudge; the Progress tab is the recap.

    func scheduleWeeklyCheckIn() {
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = "Your week in review"
        content.body = "See how this week stacked up — and what's next."
        content.sound = .default
        var comps = DateComponents(); comps.weekday = 1; comps.hour = 18   // Sunday 18:00 local
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        // Stable id ⇒ rescheduling on each launch just refreshes the single repeating request.
        center.add(UNNotificationRequest(identifier: "momentum.weekly", content: content, trigger: trigger))
    }

    // MARK: Streak nudge (PRD §24) — gentle, never guilt; only a real streak at risk on a planned
    // day, at most one (the single dated request) per day.

    func scheduleStreakNudge(streak: Int, isPlannedDayToday: Bool, hasWorkedOutToday: Bool) {
        center.removePendingNotificationRequests(withIdentifiers: ["momentum.streak"])
        guard StreakNudge.shouldNudge(streak: streak, isPlannedDay: isPlannedDayToday, hasWorkedOutToday: hasWorkedOutToday)
        else { return }
        let now = Date()
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = 18; comps.minute = 30
        guard let fire = Calendar.current.date(from: comps), fire > now else { return }   // evening still ahead
        let content = UNMutableNotificationContent()
        content.title = "Keep it rolling"
        content.body = "A quick session keeps your \(streak)-day streak alive — no pressure if today's a rest."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: "momentum.streak", content: content, trigger: trigger))
    }

    /// Show banners while foregrounded, so the "plan updated" nudge is actually seen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: Reminder payloads (pure — unit-tested)

    struct ReminderPayload: Sendable, Equatable {
        let id: String
        let title: String
        let body: String
        let fireComponents: DateComponents
    }

    static func reminderPayloads(for plan: TrainingPlan, now: Date = Date(),
                                 hour: Int, minute: Int, calendar: Calendar = .current) -> [ReminderPayload] {
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let upcoming = plan.sessions
            .filter { $0.status != .completed && $0.completedWorkout == nil
                      && $0.date >= today && $0.date <= horizon }
            .sorted { $0.date < $1.date }
        return upcoming.compactMap { session in
            var comps = calendar.dateComponents([.year, .month, .day], from: session.date)
            comps.hour = hour; comps.minute = minute
            // Don't schedule a fire time that's already passed (e.g. today after the reminder hour).
            guard let fire = calendar.date(from: comps), fire > now else { return nil }
            return ReminderPayload(id: "momentum.session.\(session.id.uuidString)",
                                   title: reminderTitle(session),
                                   body: PlanCoaching.brief(for: session),
                                   fireComponents: comps)
        }
    }

    private static func reminderTitle(_ s: PlannedSession) -> String {
        switch s.discipline {
        case .running: "Run day"
        case .cycling: "Ride day"
        case .walking: "Walk day"
        case .strength: "Lift day"
        }
    }
}

/// The streak-nudge decision (PRD §24), pure so it's unit-testable: nudge only when there's a real
/// streak (≥3) at risk — a planned day not yet trained. Never guilt; the caller schedules at most one
/// dated request per day.
enum StreakNudge {
    static func shouldNudge(streak: Int, isPlannedDay: Bool, hasWorkedOutToday: Bool) -> Bool {
        streak >= 3 && isPlannedDay && !hasWorkedOutToday
    }
}
