import UIKit
import SwiftData
import UserNotifications

/// All coaching producers enter through their durable inbox receipt. Select at presentation time,
/// after save sheets and ordinary confirmations finish; never spend a budget on an invisible toast.
@MainActor
enum CoachSurface {
    private static weak var context: ModelContext?
    private static var budget = CoachOpeningBudget()
    private static var pushTask: Task<Void, Never>?
    private static var schedulingPush = false

    static func route(for kind: CoachingEvent.Kind, focusSessionID: UUID? = nil) -> AppToast.Route {
        .deepLink(NotificationRoute.forCoaching(kind, focusSessionID: focusSessionID))
    }

    static func configure(in context: ModelContext) {
        self.context = context
        ToastCenter.shared.nextCoachingToast = { nextToast() }
        CoachMessageLifecycle.expire(in: context)
        request(in: context)
    }

    static func request(in context: ModelContext) {
        if self.context == nil { self.context = context }
        if UIApplication.shared.applicationState == .background {
            queuePush()
        } else {
            ToastCenter.shared.requestCoaching()
        }
    }

    static func backgrounded() {
        budget.reset()
        ToastCenter.shared.cancelCoaching()
        // A decision may have arrived while a save sheet held its toast. Leaving the app
        // must not strand that unseen update. Recheck after UIKit completes the transition.
        queuePush()
    }

    private static func queuePush() {
        pushTask?.cancel()
        pushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await schedulePush()
        }
    }

    static func nextToast(now: Date = Date()) -> AppToast? {
        guard UIApplication.shared.applicationState == .active, budget.available,
              let context else { return nil }
        CoachMessageLifecycle.expire(in: context, now: now)
        for receipt in CoachMessageLifecycle.candidates(in: context, now: now) where enabled(receipt) {
            guard let note = CoachMessageLifecycle.notification(receipt.id, in: context) else { continue }
            return AppToast(icon: receipt.priority >= 90 ? "heart.text.clipboard" : "figure.run",
                            line: NotificationCopy.clean(note.title),
                            route: .deepLink(CoachMessageLifecycle.route(receipt)), notificationID: receipt.id)
        }
        return nil
    }

    private static func enabled(_ receipt: CoachMessageReceipt) -> Bool {
        receipt.topic == "refuel" ? NotificationPrefs.refuelEnabled() : NotificationPrefs.coachingEnabled()
    }

    static func displayed(_ id: UUID, in context: ModelContext, now: Date = Date()) -> Bool {
        guard budget.available, let receipt = CoachMessageReceipt.fetch(id, in: context),
              receipt.eligible(at: now) else { return false }
        // Even a disk failure cannot create a cascade of visible messages in this opening.
        budget.displayed(id)
        return CoachMessageLifecycle.record(id, action: .displayed, in: context, now: now, source: "toast")
    }

    private static func schedulePush() async {
        guard !schedulingPush, UIApplication.shared.applicationState == .background,
              let context else { return }
        schedulingPush = true
        defer { schedulingPush = false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus),
              UIApplication.shared.applicationState == .background else { return }
        let now = Date(), fire = now.addingTimeInterval(3)
        guard NotificationQuietHours.allows(fire),
              let receipt = CoachMessageLifecycle.candidates(in: context, now: now).first(where: { enabled($0) && $0.pushScheduledAt == nil && $0.expiresAt > fire }),
              let note = CoachMessageLifecycle.notification(receipt.id, in: context),
              CoachPushBudget.canConsume(now: now) else { return }
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.clean(note.title)
        content.body = NotificationCopy.clean(note.body)
        content.sound = .default
        content.relevanceScore = receipt.priority >= 90 ? 1 : 0.8
        NotificationService.decorate(content, family: .coaching, route: CoachMessageLifecycle.route(receipt))
        content.categoryIdentifier = NotificationService.coachingCategory
        let messageID = receipt.id
        content.userInfo["momentum.coachMessageID"] = messageID.uuidString
        do {
            try await center.add(UNNotificationRequest(identifier: "momentum.update.\(messageID.uuidString)", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
            // A viewed message or foreground transition while awaiting the OS cancels the request.
            guard self.context === context,
                  let currentReceipt = CoachMessageReceipt.fetch(messageID, in: context),
                  currentReceipt.eligible(at: Date()), UIApplication.shared.applicationState == .background else {
                CoachMessageLifecycle.cancelPush(messageID); return
            }
            // Persist first: neither the daily allowance nor an in-memory receipt is spent
            // when the disk rejects this update. The OS request is cancelled on failure.
            guard CoachPushBudget.canConsume(now: now) else {
                CoachMessageLifecycle.cancelPush(messageID); return
            }
            try commitPushSchedule(currentReceipt, in: context, now: now)
            _ = CoachPushBudget.tryConsume(now: now)
            AdaptiveAnalytics.emit("push_notification_scheduled", reason: "coaching")
        } catch {
            CoachMessageLifecycle.cancelPush(messageID)
        }
    }

    static func commitPushSchedule(_ receipt: CoachMessageReceipt, in context: ModelContext,
                                   now: Date, commit: (ModelContext) throws -> Void = { try $0.save() }) throws {
        let previous = receipt.pushScheduledAt
        receipt.pushScheduledAt = now
        do { try commit(context) }
        catch { receipt.pushScheduledAt = previous; throw error }
    }
}
