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
@MainActor
enum CoachSurface {
    /// Where a coaching kind lands when tapped: easings and recovery days route to the Health hub
    /// (the readiness "why" lives there); reshapes and moves route to the Plan board (the sessions
    /// carry their rationale lines).
    static func route(for kind: CoachingEvent.Kind) -> AppToast.Route {
        switch kind {
        case .ease, .recover: .progressSegment("Health")
        case .recalibrate, .moved: .tab(.plan)
        }
    }

    static func deliver(kind: CoachingEvent.Kind, headline: String, detail: String) {
        guard NotificationPrefs.coachingEnabled() else { return }
        if UIApplication.shared.applicationState == .background {
            guard CoachPushBudget.tryConsume() else { return }
            let content = UNMutableNotificationContent()
            content.title = headline
            content.body = detail
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "momentum.update.\(UUID().uuidString)",
                                      content: content, trigger: trigger))
        } else {
            ToastCenter.shared.show(icon: kind.systemImage, line: headline,
                                    route: route(for: kind), delay: 1.2)
        }
    }
}
