import Foundation
import SwiftData
import BackgroundTasks
import UserNotifications

/// The morning readiness knock (enterprise pass 2026-08-15): a BGAppRefresh task that wakes
/// around 6:30, computes the day's readiness through the ONE recipe (`ReadinessToday` — never a
/// side blend), publishes it to the strip/watch cache, and posts one quiet local notification
/// ("Readiness 82 · Solid sleep …"). Opportunistic by design — iOS decides if and when the task
/// actually runs, so a silent morning is normal and costs nothing: the number is recomputed the
/// moment the app opens anyway. Gated by Settings → Notifications → Morning readiness.
@MainActor
enum MorningReadinessRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in project.yml.
    static let taskID = "com.ephraimbel.momentum.app.readiness"
    /// Stable notification id — at most one readiness push exists; a rerun replaces, never stacks.
    static let notificationID = "momentum.readiness"

    /// Called from `MomentumApp.init` — BGTask handlers must register before launch completes.
    static func register(health: any HealthServing) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // The registration queue is .main, so this closure is already on the main actor —
            // assumeIsolated threads that fact through to the @MainActor handler without a hop
            // the expiration handler could outrace.
            MainActor.assumeIsolated { handle(refresh, health: health) }
        }
    }

    /// Re-arm for the next morning. Safe to call repeatedly (one pending request per id).
    static func schedule(now: Date = Date(), calendar: Calendar = .current) {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = nextMorning(after: now, calendar: calendar)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The next 6:30 — early enough to greet the morning, late enough that last night's sleep
    /// samples have landed in Health. Pure and fixture-tested.
    static func nextMorning(after now: Date, calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = 6; comps.minute = 30
        let todaysSixThirty = calendar.date(from: comps) ?? now
        if todaysSixThirty > now { return todaysSixThirty }
        return calendar.date(byAdding: .day, value: 1, to: todaysSixThirty) ?? now
    }

    private static func handle(_ task: BGAppRefreshTask, health: any HealthServing) {
        schedule()   // re-arm FIRST — the chain must survive a failed or expired run
        let work = Task { @MainActor in
            defer { task.setTaskCompleted(success: true) }
            guard NotificationPrefs.morningReadinessEnabled() else { return }
            let context = PersistenceController.shared.container.mainContext
            // Readiness looks back weeks, not a career — bound both fetches so a long-tenured
            // athlete's background wake doesn't walk the whole table against the BG task's
            // expiration budget (90d comfortably covers every chronic window the model reads;
            // perf audit 2026-08-16).
            let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? .distantPast
            let workouts = (try? context.fetch(FetchDescriptor<Workout>(
                predicate: #Predicate { $0.startedAt >= cutoff }))) ?? []
            let checkins = (try? context.fetch(FetchDescriptor<DailyCheckin>(
                predicate: #Predicate { $0.date >= cutoff }))) ?? []
            guard !workouts.isEmpty,   // a fresh install has no readiness story to tell yet
                  let readiness = await ReadinessToday.compute(health: health, workouts: workouts,
                                                               checkins: checkins),
                  !Task.isCancelled else { return }
            // The strip, widget cache, and watch wake up to today's number too — the push is
            // just the knock; the same score is already on every surface when they arrive.
            ReadinessToday.publish(readiness)
            push(readiness)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// One line, the hub's own vocabulary: the score leads, the driver (with its confidence
    /// qualifier) explains, the band's no-shame guidance closes.
    static func push(_ r: MorningReadiness) {
        let content = UNMutableNotificationContent()
        content.title = "Readiness \(r.score)"
        content.body = "\(r.displayDriverWithConfidence). \(r.guidance)"
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil))
    }
}
