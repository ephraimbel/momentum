import Foundation
import SwiftData
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

    /// Siri meal receipts: the category carries the Undo action (see `SiriMealLogger.postReceipt`).
    /// nonisolated: referenced from the nonisolated delegate callback.
    nonisolated static let mealReceiptCategory = "momentum.meal.receipt"
    nonisolated static let mealUndoAction = "momentum.meal.undo"

    override init() {
        super.init()
        center.delegate = self
        // The app's one notification category set — replace-not-merge semantics, so every
        // category the app uses must be registered here together.
        let undo = UNNotificationAction(identifier: Self.mealUndoAction, title: "Undo",
                                        options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.mealReceiptCategory, actions: [undo],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// Notification actions land here — currently just the meal receipt's Undo, which removes
    /// the Siri-logged meal (safe if it's already gone).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        guard action == Self.mealUndoAction,
              let idString = info["mealID"] as? String,
              let id = UUID(uuidString: idString) else {
            completionHandler()
            return
        }
        Task { @MainActor in
            SiriMealLogger.undoMeal(id: id, in: PersistenceController.shared.container.mainContext)
            completionHandler()
        }
    }

    /// Siri meal receipts start life under PROVISIONAL authorization (granted silently mid-Siri,
    /// delivered quietly to Notification Center — no banner). The athlete who logs by voice wants
    /// to SEE the receipt land, so the app's next open asks properly, once: the full system
    /// prompt, only when a receipt has actually been posted and delivery isn't full yet. The
    /// flag clears after one ask — never a nag, whatever they choose.
    static func promoteReceiptAuthorizationIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SiriMealLogger.receiptPostedKey) else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .provisional, .notDetermined:
                defaults.set(false, forKey: SiriMealLogger.receiptPostedKey)
                center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            default:
                defaults.set(false, forKey: SiriMealLogger.receiptPostedKey)
            }
        }
    }

    func requestAuthorization(completion: (() -> Void)? = nil) {
        // `completion` always fires on the main thread once the prompt is resolved (or right away if
        // already determined), so callers can advance a flow only after the system alert is dismissed.
        let finish = { DispatchQueue.main.async { completion?() } }
        // Re-acquire the (non-Sendable) center inside the closure rather than capturing it.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { finish(); return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in finish() }
        }
    }

    /// Resync per-session reminders to the plan's upcoming sessions (next 7 days). Replaces every
    /// previously scheduled momentum reminder, so moved/recalibrated/deleted sessions stay correct.
    func schedulePlannedReminders(_ plan: TrainingPlan?) {
        // Never prompts — scheduling while unauthorized is harmless (iOS won't deliver); the ASK
        // happens only at explicit consent moments (onboarding's reminders step, the bell).
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

    // MARK: Trial-ending reminder (paywall redesign 2026-08-05) — the promise page two of the
    // onboarding paywall makes. Scheduled by `PaywallCheckout` the moment a purchase WITH a trial
    // lands, two days before billing starts. Honest by construction: it names the price and the
    // renewal, and scheduling while unauthorized is harmless (iOS just won't deliver it). Static
    // like the rest timer — one-shot, no delegate needed.

    static let trialReminderID = "momentum.trialReminder"

    static func scheduleTrialReminder(trialDays: Int, renewText: String) {
        // A 1–2 day trial has no "two days before" to speak of; skip rather than fire instantly.
        guard trialDays > 2 else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [trialReminderID])
        let content = UNMutableNotificationContent()
        content.title = "Your free trial ends in 2 days"
        let endDate = Date().addingTimeInterval(Double(trialDays) * 86_400)
        content.body = "momentum Pro renews at \(renewText) on \(endDate.formatted(date: .abbreviated, time: .omitted)). Cancel anytime before then."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: Double(trialDays - 2) * 86_400, repeats: false)
        center.add(UNNotificationRequest(identifier: trialReminderID, content: content, trigger: trigger))
    }

    // MARK: Sunday check-in (PRD §24) — a weekly recap nudge; the Progress tab is the recap.

    func scheduleWeeklyCheckIn() {
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

    /// Show banners while foregrounded, so the "plan updated" nudge is actually seen — except the
    /// rest-timer alert, which is redundant here: this delegate only fires while the app is active,
    /// and the in-app rest ring is already counting down (that notification is cancelled on
    /// skip/finish, never when the ring reaches 0 naturally). Suppress it so it doesn't fire a
    /// banner+sound over the ring every set.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier == Self.restID {
            completionHandler([])
            return
        }
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
