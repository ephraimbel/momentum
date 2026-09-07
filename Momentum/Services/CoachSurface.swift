import UIKit
import UserNotifications

/// How a coaching decision reaches the athlete's eyes (enterprise pass 2026-08-15). Every decision
/// is already durable — `CoachingEvent.record` keeps the receipt and mirrors it into the bell
/// inbox — so this layer only decides the *live* surface:
///  • app in the foreground → the toast capsule, after a beat so it never lands on top of the
///    post-save celebration;
///  • app in the background → one local push, budgeted to **one coaching push per local day**
///    (`CoachPushBudget`) and gated by the Settings toggle. Anything past the budget waits
///    silently in the inbox — updated, never nagged.
/// Either surface carries the SAME `NotificationRoute` the inbox row keeps (notification pass
/// 2026-09-06): a tap opens the session that moved, the Plan board whose paces changed, or the
/// Health hub whose readiness drove an easing.
@MainActor
enum CoachSurface {
    /// Where a coaching kind lands when tapped. `focusSessionID` is the session a move was about,
    /// when the decision knows it.
    static func route(for kind: CoachingEvent.Kind, focusSessionID: UUID? = nil) -> AppToast.Route {
        .deepLink(NotificationRoute.forCoaching(kind, focusSessionID: focusSessionID))
    }

    static func deliver(kind: CoachingEvent.Kind, headline: String, detail: String,
                        focusSessionID: UUID? = nil) {
        guard NotificationPrefs.coachingEnabled() else { return }
        let route = NotificationRoute.forCoaching(kind, focusSessionID: focusSessionID)
        if UIApplication.shared.applicationState == .background {
            guard CoachPushBudget.tryConsume() else { return }
            let content = UNMutableNotificationContent()
            content.title = NotificationCopy.clean(headline)
            content.body = NotificationCopy.clean(detail)
            content.sound = .default
            content.relevanceScore = 0.9
            NotificationService.decorate(content, family: .coaching, route: route)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "momentum.update.\(UUID().uuidString)",
                                      content: content, trigger: trigger))
        } else {
            ToastCenter.shared.show(icon: kind.systemImage, line: NotificationCopy.clean(headline),
                                    route: .deepLink(route), delay: 1.2)
        }
    }
}
