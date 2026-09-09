import Foundation
import UIKit
import SwiftData
import UserNotifications

/// Local notifications (PRD §24, notification pass 2026-09-06) — the "updates" half of the
/// adaptive coach, and the way the plan reaches an athlete who is not looking at it.
///  • Everything the PLAN says is decided by `NotificationPlanner` in one pure pass and resynced
///    here: one reminder per training day carrying the *current* prescription, a quiet catch-up
///    the morning after a missed session, one win-back after ten silent days, the Sunday preview,
///    race eve and race morning. Every resync replaces the lot, so a moved, eased, completed or
///    deleted session can never leave a stale line behind.
///  • Coaching decisions ("plan updated") travel through `CoachingEvent.record` → `CoachSurface`
///    (foreground toast, or one budgeted background push per day), not through this service.
///  • **Every notification carries a `NotificationRoute`.** A tap lands where the notification is
///    about: the session, the moved session, the Health hub, Settings. The delegate below decodes
///    it and drops it into `AppRouter.pendingNotificationRoute`; `RootView` does the rest.
/// No remote push; everything is local and reconstructable from the plan.
@MainActor
final class NotificationService: NSObject, NotificationServing, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    /// The shell's mailbox for a tapped notification, and the event sink for open rates. Both are
    /// wired once in `MomentumApp.init`, after the router exists; a tap that arrives before the
    /// shell mounts waits in the mailbox until the tab shell consumes it.
    weak var router: AppRouter?
    weak var analytics: (any AnalyticsServing)?

    /// Session reminders ride the athlete's own training rhythm (enterprise pass 2026-08-15):
    /// a custom time from Settings wins, else `ReminderTiming` reads the Athlete Model's
    /// hour-of-day histogram, else everyone's 7:30 default. Read fresh on every resync, so a
    /// Settings change or a shifted habit takes effect at the very next reschedule.
    private var reminderTime: (hour: Int, minute: Int) {
        ReminderTiming.reminderTime(histogram: profile?.athlete?.trainingHourHistogram ?? [],
                                    custom: NotificationPrefs.customReminderTime())
    }

    private var profile: UserProfile? {
        var descriptor = FetchDescriptor<UserProfile>()
        descriptor.fetchLimit = 1
        return (try? PersistenceController.shared.availableContainer?.mainContext.fetch(descriptor))?.first
    }

    /// Siri meal receipts: the category carries the Undo action (see `SiriMealLogger.postReceipt`).
    /// nonisolated: referenced from the nonisolated delegate callback.
    nonisolated static let mealReceiptCategory = "momentum.meal.receipt"
    nonisolated static let mealUndoAction = "momentum.meal.undo"
    nonisolated static let coachingCategory = "momentum.coaching.update"

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
            UNNotificationCategory(identifier: Self.coachingCategory, actions: [],
                                   intentIdentifiers: [], options: [.customDismissAction]),
        ])
    }

    // MARK: Taps

    /// A tapped notification lands where it is about. The meal receipt's Undo removes the
    /// Siri-logged meal (safe if it's already gone); the default tap decodes the route the
    /// notification was scheduled with and hands it to the shell. Coaching dismissals only
    /// update the durable receipt; they never navigate or count as an open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        if action == UNNotificationDismissActionIdentifier {
            Task { @MainActor in
                if let raw = info["momentum.coachMessageID"] as? String,
                   let id = UUID(uuidString: raw),
                   let context = PersistenceController.shared.availableContainer?.mainContext {
                    CoachMessageLifecycle.record(id, action: .dismissed, in: context, source: "push")
                }
                completionHandler()
            }
            return
        }
        if action == Self.mealUndoAction {
            guard let idString = info["mealID"] as? String, let id = UUID(uuidString: idString) else {
                completionHandler()
                return
            }
            Task { @MainActor in
                if let context = PersistenceController.shared.availableContainer?.mainContext {
                    SiriMealLogger.undoMeal(id: id, in: context)
                }
                completionHandler()
            }
            return
        }
        guard action == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let route = NotificationRoute(userInfo: info)
        let family = info[NotificationRoute.familyKey] as? String
        Task { @MainActor in
            if let raw = info["momentum.coachMessageID"] as? String,
               let id = UUID(uuidString: raw),
               let context = PersistenceController.shared.availableContainer?.mainContext {
                CoachMessageLifecycle.record(id, action: .opened, in: context, source: "push")
            }
            self.open(route, family: family)
            completionHandler()
        }
    }

    /// The one door for a tapped notification (the delegate above, and the DEBUG launch arg that
    /// stands in for a tap). Counted per family whether or not it routes, so an open rate exists
    /// for every kind of notification the app sends.
    func open(_ route: NotificationRoute?, family: String?) {
        analytics?.log(.notificationOpened(family: family ?? "unknown", routed: route != nil))
        guard let route else { return }
        router?.pendingNotificationRoute = route
    }

    /// Show banners while foregrounded, so a coaching nudge is actually seen — except the
    /// rest-timer alert, which is redundant here: this delegate only fires while the app is active,
    /// and the in-app rest ring is already counting down (that notification is cancelled on
    /// skip/finish, never when the ring reaches 0 naturally). Suppress it so it doesn't fire a
    /// banner+sound over the ring every set. Quiet families carry no sound, so `.sound` is a no-op
    /// for them.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier == Self.restID {
            completionHandler([])
            return
        }
        if notification.request.content.userInfo["momentum.coachMessageID"] != nil {
            // A push racing a foreground transition joins the same one-message allowance.
            completionHandler([])
            Task { @MainActor in
                if let context = PersistenceController.shared.availableContainer?.mainContext {
                    CoachSurface.request(in: context)
                }
            }
            return
        }
        completionHandler([.banner, .sound])
    }

    // MARK: Permission

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

    /// The system's answer, for surfaces that must tell the truth about it (Settings shows an
    /// "off in iOS Settings" row when the athlete said no there, instead of five toggles that
    /// silently do nothing).
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// `openSettingsIfDenied`: iOS raises its permission alert exactly once per install. When the
    /// athlete already said no, a tap on "Turn on reminders" used to advance in silence, which read
    /// as a dead button (owner report 2026-09-05); the onboarding beat now sends them to the app's
    /// notification settings instead, where the switch actually lives. Other callers (the bell)
    /// keep the quiet behaviour.
    func requestAuthorization(completion: ((Bool) -> Void)?) {
        requestAuthorization(openSettingsIfDenied: false, completion: completion)
    }

    func requestAuthorization(openSettingsIfDenied: Bool, completion: ((Bool) -> Void)?) {
        // `completion` always fires on the main thread once the prompt is resolved (or right away if
        // already determined), so callers can advance a flow only after the system alert is dismissed.
        let finish = { (granted: Bool) in DispatchQueue.main.async { completion?(granted) } }
        // Re-acquire the (non-Sendable) center inside the closure rather than capturing it.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in finish(granted) }
            case .authorized, .provisional, .ephemeral:
                finish(true)
            case .denied:
                if openSettingsIfDenied, let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    DispatchQueue.main.async { UIApplication.shared.open(url) }
                }
                finish(false)
            @unknown default:
                finish(false)
            }
        }
    }

    // MARK: The plan's schedule (resync)

    /// Resync everything the plan says to the plan as it stands now. Replaces every previously
    /// scheduled `momentum.plan.` request, so moved/recalibrated/deleted sessions stay correct.
    func schedulePlannedReminders(_ plan: TrainingPlan?) {
        // Never prompts — scheduling while unauthorized is harmless (iOS won't deliver); the ASK
        // happens only at explicit consent moments (onboarding's reminders step, the bell).
        // Reminders off in Settings → the planner schedules nothing of that family AND the sweep
        // below clears what's pending, so a toggle takes effect immediately.
        let time = reminderTime
        var options = NotificationPlanner.Options()
        options.sessionReminders = NotificationPrefs.sessionRemindersEnabled()
        options.weekly = NotificationPrefs.weeklyEnabled()
        options.distanceUnit = DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto
        let payloads = NotificationPlanner.payloads(for: plan, hour: time.hour, minute: time.minute,
                                                    options: options).filter { payload in
            guard let date = Calendar.current.date(from: payload.fire) else { return false }
            return NotificationQuietHours.allows(date)
        }
        Self.replace(prefix: NotificationPlanner.prefix, legacy: Self.legacyPlanIDs, with: payloads)
        // The trial reminder rides the same resync so its body can say what the athlete has done.
        Self.refreshTrialReminder(plan: plan)
    }

    /// Requests from before this pass (per-session ids without the `plan.` segment, and the old
    /// repeating Sunday request) are swept on the first resync so an updated install never keeps
    /// two generations of reminders.
    nonisolated private static func legacyPlanIDs(_ id: String) -> Bool {
        id.hasPrefix("momentum.session.") || id == "momentum.weekly"
    }

    /// The Sunday review rides the plan resync (its body previews the plan's own coming week), so
    /// the Settings toggle and Today's bootstrap both land here.
    func scheduleWeeklyCheckIn() {
        schedulePlannedReminders(profile?.plan)
    }

    /// Preference changes withdraw already scheduled activity/coaching requests in quiet hours.
    /// Live rest timers and the promised billing reminder are deliberately unaffected.
    static func applyQuietHoursToPending() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.compactMap { request -> String? in
                guard let raw = request.content.userInfo[NotificationRoute.familyKey] as? String,
                      let family = NotificationFamily(rawValue: raw),
                      family != .rest, family != .trial else { return nil }
                let fire = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                    ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                return fire.map { NotificationQuietHours.allows($0) ? nil : request.identifier } ?? nil
            }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Remove every pending request under `prefix` (plus any `legacy` match), then add `payloads`.
    nonisolated private static func replace(prefix: String, legacy: @escaping @Sendable (String) -> Bool,
                                            with payloads: [LocalNotificationPayload]) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
            let center = UNUserNotificationCenter.current()
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) || legacy($0) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            for p in payloads {
                let trigger = UNCalendarNotificationTrigger(dateMatching: p.fire, repeats: false)
                center.add(UNNotificationRequest(identifier: p.id, content: content(for: p), trigger: trigger)) { error in
                    if error == nil { AdaptiveAnalytics.emit("push_notification_scheduled", reason: p.family.rawValue) }
                }
            }
        }
    }

    /// One content builder for every payload, so the route, the family, the thread and the
    /// quiet/sounded choice can never drift between families.
    nonisolated static func content(for p: LocalNotificationPayload) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = p.title
        content.body = p.body
        content.sound = p.sound ? .default : nil
        content.relevanceScore = p.relevance
        decorate(content, family: p.family, route: p.route)
        return content
    }

    /// The route and family every notification carries, for the one-off families built elsewhere
    /// (rest timer, trial, coaching push, readiness, Siri receipt).
    nonisolated static func decorate(_ content: UNMutableNotificationContent, family: NotificationFamily,
                                     route: NotificationRoute?) {
        content.threadIdentifier = family.thread
        var info: [String: String] = [NotificationRoute.familyKey: family.rawValue]
        if let route { info[NotificationRoute.userInfoKey] = route.rawValue }
        content.userInfo = info
    }

    // MARK: Day nudges (streak, first run) — dated one-shots, at most one each per day

    static let streakID = "momentum.streak"
    static let firstRunID = "momentum.firstRun"

    /// Streak nudge (PRD §24) — gentle, never guilt; only a real streak at risk on a planned day.
    func scheduleStreakNudge(streak: Int, isPlannedDayToday: Bool, hasWorkedOutToday: Bool) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.streakID])
        guard NotificationPrefs.streakEnabled(),
              StreakNudge.shouldNudge(streak: streak, isPlannedDay: isPlannedDayToday, hasWorkedOutToday: hasWorkedOutToday)
        else { return }
        let now = Date()
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = 18; comps.minute = 30
        guard let fire = Calendar.current.date(from: comps), fire > now, NotificationQuietHours.allows(fire) else { return }   // evening still ahead
        let payload = LocalNotificationPayload(
            id: Self.streakID, family: .streak,
            title: "Keep it rolling",
            body: Self.streakBody(streak: streak),
            fire: comps, route: .today, sound: true, relevance: 0.7)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: payload.id, content: Self.content(for: payload), trigger: trigger))
    }

    nonisolated static func streakBody(streak: Int) -> String {
        "A short session keeps your streak at \(streak) days. No pressure if today is rest."
    }

    /// First-run nudge (2026-09-06) — a new athlete has no streak to protect, so the streak nudge
    /// never reaches them, and the first days of a plan are exactly where trials go dark. One
    /// gentle evening line on a day their plan holds a run they have not yet done, only until their
    /// first workout exists. Opens Today, where the map and Start are.
    static func scheduleFirstRunNudge(totalWorkouts: Int, plannedRunToday: PlannedSession?,
                                      hasWorkedOutToday: Bool, now: Date = Date(),
                                      distanceUnit: DistanceUnit = .auto) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [firstRunID])
        guard NotificationPrefs.sessionRemindersEnabled(),
              let session = plannedRunToday,
              FirstRunNudge.shouldNudge(totalWorkouts: totalWorkouts, hasPlannedRunToday: true,
                                        hasWorkedOutToday: hasWorkedOutToday) else { return }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = 17; comps.minute = 30
        guard let fire = Calendar.current.date(from: comps), fire > now, NotificationQuietHours.allows(fire) else { return }   // evening still ahead
        let payload = LocalNotificationPayload(
            id: firstRunID, family: .firstRun,
            title: "Your first run is ready",
            body: NotificationCopy.clean(PlanCoaching.brief(for: session, distanceUnit: distanceUnit))
                + ". It's on the map whenever you are.",
            fire: comps, route: .today, sound: true, relevance: 0.9)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: payload.id, content: content(for: payload), trigger: trigger))
    }

    /// A logged workout settles the day: the evening nudges are withdrawn on the spot, not at the
    /// next Today pass. Called from `WorkoutCompletion.adapt`, so the live finish and crash
    /// recovery both clear them. (The morning catch-up is the plan resync's to keep or drop: the
    /// same save resyncs, and the completed session simply stops earning one.)
    static func clearDayNudgesAfterWorkout() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [streakID, firstRunID])
    }

    #if DEBUG
    /// `--notify-fire=<route>`: one real local notification, four seconds out, carrying `route`.
    /// Exists so a UI test can tap an actual banner and prove the delegate lands the athlete on
    /// the destination. DEBUG-only; never ships.
    static func debugFire(route: NotificationRoute) {
        let content = UNMutableNotificationContent()
        content.title = "momentum routing check"
        content.body = "Tap to open \(route.rawValue)"
        content.sound = .default
        decorate(content, family: .coaching, route: route)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 4, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "momentum.debug.fire", content: content, trigger: trigger))
    }
    #endif

    // MARK: Refuel cue (fuel integration 2026-09-06) — one nudge toward carbs and protein after a
    // long run or an exerting session, within the existing post-workout reminder window.
    // Shares the coaching allowance, so it cannot stack another interruption over recovery advice.
    // Withdrawn the moment a meal is logged (the athlete already did the thing), and replaced by
    // the next exerting session, so at most one is ever pending.

    static let refuelID = "momentum.fuel.refuel"

    /// The payload for a saved workout, or nil when the session was not exerting or the finish is
    /// too far behind to have a window left. Pure given the workout; tested on fixtures.
    static func refuelPayload(for workout: Workout, now: Date = Date(),
                              calendar: Calendar = .current) -> LocalNotificationPayload? {
        guard let cue = PostWorkoutFuelCue.cue(for: workout) else { return nil }
        let endedAt = workout.startedAt.addingTimeInterval(max(workout.elapsedS, workout.durationS))
        guard let fire = PostWorkoutFuelCue.fireDate(endedAt: endedAt, now: now) else { return nil }
        return LocalNotificationPayload(
            id: refuelID, family: .refuel,
            title: cue.title, body: cue.body,
            fire: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire),
            route: .fuel, sound: true, relevance: 0.8)
    }

    /// Persist the cue for a workout that just became real. The shared coach presenter decides
    /// whether it earns a toast or push before the window closes. Called from
    /// `WorkoutCompletion.adapt`, so the live finish and crash recovery both reach it.
    static func scheduleRefuelCue(for workout: Workout, in context: ModelContext, now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [refuelID])
        guard NotificationPrefs.refuelEnabled(),
              let payload = refuelPayload(for: workout, now: now),
              let fire = Calendar.current.date(from: payload.fire), NotificationQuietHours.allows(fire) else { return }
        AppNotification.post(kind: .coaching, title: payload.title, body: payload.body, on: now,
                             in: context, dedupeToken: "refuel-\(workout.id.uuidString)", daily: false,
                             route: .fuel, coachingPriority: 20, expiresAt: fire, topic: "refuel")
    }

    /// A logged meal answers the cue: withdraw it wherever it still waits.
    static func cancelRefuelCue() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [refuelID])
        center.removeDeliveredNotifications(withIdentifiers: [refuelID])
        if let context = PersistenceController.shared.availableContainer?.mainContext {
            for receipt in CoachMessageLifecycle.candidates(in: context) where receipt.topic == "refuel" {
                CoachMessageLifecycle.record(receipt.id, action: .expired, in: context, source: "meal_logged")
            }
        }
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
            ? "Time for your next set." : "Time for your next \(NotificationCopy.clean(exerciseName)) set."
        content.sound = .default
        // No route: the live session is an overlay over the whole shell, so opening the app IS
        // landing on it.
        decorate(content, family: .rest, route: nil)
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
    // renewal, and scheduling while unauthorized is harmless (iOS just won't deliver it). Opens
    // Settings, where Manage subscription is.

    static let trialReminderID = "momentum.trialReminder"
    /// Where the running trial is remembered so the reminder can be re-issued with fresh copy.
    static let trialStartKey = "trial.startedAt"
    static let trialDaysKey = "trial.days"
    static let trialRenewTextKey = "trial.renewText"

    /// Called the moment a trial starts (the paywall's promise). Remembers the trial and issues
    /// the first version of the reminder; every plan resync then calls `refreshTrialReminder`,
    /// which re-issues it with what the athlete has actually done by then.
    static func scheduleTrialReminder(trialDays: Int, renewText: String, now: Date = Date()) {
        let d = UserDefaults.standard
        d.set(now, forKey: trialStartKey)
        d.set(trialDays, forKey: trialDaysKey)
        d.set(renewText, forKey: trialRenewTextKey)
        refreshTrialReminder(plan: nil, now: now)
    }

    /// Re-issue the trial reminder from the remembered trial: the policy's fire time (nine in the
    /// morning the day before a short trial bills, two days before a week long one, never inside
    /// the first day), and a body that opens with the sessions the athlete has logged since the
    /// trial began. Idempotent: the same request id replaces the previous one. Once the trial has
    /// billed or lapsed the request and the memory of it are cleared.
    static func refreshTrialReminder(plan: TrainingPlan?, now: Date = Date()) {
        let d = UserDefaults.standard
        let center = UNUserNotificationCenter.current()
        guard let start = d.object(forKey: trialStartKey) as? Date,
              let renewText = d.string(forKey: trialRenewTextKey) else { return }
        let days = d.integer(forKey: trialDaysKey)
        let end = TrialReminderPolicy.endDate(trialStart: start, trialDays: days)
        guard now < end else {
            center.removePendingNotificationRequests(withIdentifiers: [trialReminderID])
            d.removeObject(forKey: trialStartKey); d.removeObject(forKey: trialDaysKey); d.removeObject(forKey: trialRenewTextKey)
            return
        }
        guard let fire = TrialReminderPolicy.fireDate(trialStart: start, trialDays: days, now: now) else {
            // Too short a trial to warn honestly, or the moment has passed: nothing pending.
            center.removePendingNotificationRequests(withIdentifiers: [trialReminderID])
            return
        }
        let completed = plan?.sessions.filter { $0.status == .completed && $0.date >= start && $0.date <= now }.count ?? 0
        let content = UNMutableNotificationContent()
        content.title = TrialReminderPolicy.title(trialDays: days)
        content.body = NotificationCopy.clean(
            TrialReminderPolicy.body(completedSessions: completed, renewText: renewText, endDate: end))
        content.sound = .default
        decorate(content, family: .trial, route: .settings)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.removePendingNotificationRequests(withIdentifiers: [trialReminderID])
        center.add(UNNotificationRequest(identifier: trialReminderID, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
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

/// The first-run nudge decision (2026-09-06), pure so it's unit-testable: only an athlete with no
/// workout logged yet, on a day whose plan holds a run they have not done. Once the first workout
/// exists the streak and session reminders take over; it never fires on a rest day.
enum FirstRunNudge {
    static func shouldNudge(totalWorkouts: Int, hasPlannedRunToday: Bool, hasWorkedOutToday: Bool) -> Bool {
        totalWorkouts == 0 && hasPlannedRunToday && !hasWorkedOutToday
    }
}
