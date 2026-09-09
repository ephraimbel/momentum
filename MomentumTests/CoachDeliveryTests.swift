import Foundation
import SwiftData
import Testing
@testable import Momentum

@MainActor
struct CoachDeliveryTests {
    private func store() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }
    private func add(_ title: String, priority: Int, at now: Date, in context: ModelContext) throws -> UUID {
        let n = AppNotification(kind: .coaching, title: title, body: title, date: now)
        let r = CoachMessageReceipt(id: n.id, now: now); r.priority = priority; r.routeRaw = NotificationRoute.plan.rawValue
        context.insert(n); context.insert(r); try context.save(); return n.id
    }

    @Test func prioritySelectionWaitsForTheCoverAndDoesNotSpendTheAllowance() async throws {
        let container = try store(), context = container.mainContext, center = ToastCenter()
        let now = Date()
        _ = try add("Week so far", priority: 40, at: now, in: context)
        var allowance = CoachOpeningBudget()
        center.nextCoachingToast = {
            guard allowance.available, let receipt = CoachMessageLifecycle.candidates(in: context).first,
                  let n = CoachMessageLifecycle.notification(receipt.id, in: context) else { return nil }
            return AppToast(icon: "figure.run", line: n.title, route: .deepLink(CoachMessageLifecycle.route(receipt)), notificationID: n.id)
        }
        center.hold("save")
        center.requestCoaching(delay: 0)
        try await Task.sleep(for: .milliseconds(30))
        #expect(center.current == nil && allowance.available)
        let recovery = try add("Recovery first", priority: 100, at: now, in: context)
        center.release("save")
        for _ in 0..<100 where center.current == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(center.current?.notificationID == recovery)
        #expect(center.current?.route == .deepLink(.plan))
        #expect(allowance.available) // Selecting/enqueueing is not display.
        allowance.displayed(recovery)
        CoachMessageLifecycle.record(recovery, action: .displayed, in: context)
        center.dismissCurrent(); center.requestCoaching(delay: 0)
        try await Task.sleep(for: .milliseconds(400))
        #expect(center.current == nil)
        allowance.reset(); center.requestCoaching(delay: 0)
        for _ in 0..<100 where center.current == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(center.current?.line == "Week so far")
        center.cancelCoaching()
    }

    @Test func readingAnySurfaceSuppressesReplayAcrossContextsAndKeepsTheRoute() throws {
        let container = try store(), context = container.mainContext, now = Date()
        let id = try add("Review ready", priority: 80, at: now, in: context)
        #expect(CoachMessageLifecycle.record(id, action: .displayed, in: context, now: now, source: "coach_updates"))
        #expect(!CoachMessageLifecycle.record(id, action: .displayed, in: context, now: now, source: "inbox"))
        let reopened = ModelContext(container)
        #expect(CoachMessageLifecycle.candidates(in: reopened, now: now).isEmpty)
        let receipt = try #require(CoachMessageReceipt.fetch(id, in: reopened))
        #expect(CoachMessageLifecycle.route(receipt) == .plan)
        #expect(CoachMessageLifecycle.record(id, action: .opened, in: reopened, now: now, source: "push"))
        #expect(receipt.openedAt == now && receipt.deliveredAt == now)
        #expect(CoachMessageLifecycle.notification(id, in: reopened)?.read == true)
    }

    @Test func expiryAndDismissalKeepHistoryButPreventAnInterruption() throws {
        let container = try store(), context = container.mainContext, now = Date()
        let stale = try add("Old review", priority: 100, at: now.addingTimeInterval(-8 * 86400), in: context)
        let dismissed = try add("Dismissed", priority: 90, at: now, in: context)
        let fresh = try add("Fresh", priority: 30, at: now, in: context)
        CoachMessageLifecycle.record(dismissed, action: .dismissed, in: context, now: now)
        CoachMessageLifecycle.expire(in: context, now: now)
        #expect(CoachMessageLifecycle.candidates(in: context, now: now).map(\.id) == [fresh])
        #expect(CoachMessageReceipt.fetch(stale, in: context)?.expiredAt == now)
        #expect(CoachMessageLifecycle.notification(stale, in: context) != nil)
        #expect(CoachMessageLifecycle.record(stale, action: .opened, in: context, now: now, source: "archive"))
    }

    @Test func aMessageReadWhileTheSaveSheetIsOpenNeverAppearsAfterDismissal() async throws {
        let container = try store(), context = container.mainContext, center = ToastCenter()
        let id = try add("Saved update", priority: 80, at: Date(), in: context)
        center.nextCoachingToast = {
            guard let r = CoachMessageLifecycle.candidates(in: context).first else { return nil }
            return AppToast(icon: "figure.run", line: "Saved update", notificationID: r.id)
        }
        center.hold("sheet"); center.requestCoaching(delay: 0)
        CoachMessageLifecycle.record(id, action: .opened, in: context, source: "inbox")
        center.release("sheet")
        try await Task.sleep(for: .milliseconds(450))
        #expect(center.current == nil)
        center.cancelCoaching()
    }

    @Test func weeklyCheckinsUseThePlansCalendarAndNeverClaimAnUnperformedChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!; calendar.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-09-10T17:00:00Z")!
        let week = AdaptiveTrainingWeek.week(containing: now, calendar: calendar)
        #expect(WeeklyCoachCheckin.note(completed: 0, planned: 3, day: 1, week: week, calendar: calendar) == nil)
        let mid = try #require(WeeklyCoachCheckin.note(completed: 2, planned: 3, day: 3, week: week, calendar: calendar))
        #expect(mid.body.contains("2 of 3") && !mid.body.contains("on track"))
        #expect(mid.expiry < week.end)
        let end = try #require(WeeklyCoachCheckin.note(completed: 3, planned: 3, day: 6, week: week, calendar: calendar))
        #expect(end.expiry == week.end && !end.body.contains("increased"))
    }

    @Test func failedPushPersistenceLeavesReceiptEligibleForRetry() throws {
        enum Fault: Error { case disk }
        let container = try store(), context = container.mainContext, now = Date()
        let id = try add("Review ready", priority: 80, at: now, in: context)
        let receipt = try #require(CoachMessageReceipt.fetch(id, in: context))
        do {
            try CoachSurface.commitPushSchedule(receipt, in: context, now: now, commit: { _ in throw Fault.disk })
            Issue.record("Expected save failure")
        } catch {}
        #expect(receipt.pushScheduledAt == nil && receipt.eligible(at: now))
        try CoachSurface.commitPushSchedule(receipt, in: context, now: now)
        #expect(CoachMessageReceipt.fetch(id, in: ModelContext(container))?.pushScheduledAt == now)
    }
}
