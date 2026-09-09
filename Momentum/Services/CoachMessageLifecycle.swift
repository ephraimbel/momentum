import Foundation
import SwiftData
import UserNotifications

/// One receipt for toast, inbox, Plan updates and notification taps. Archival reading remains
/// possible after expiry; expired or previously seen messages can never become a new interruption.
@MainActor
enum CoachMessageLifecycle {
    enum Action: String { case displayed, opened, dismissed, expired }

    static func candidates(in context: ModelContext, now: Date = Date()) -> [CoachMessageReceipt] {
        guard context.container.schema.entities.contains(where: { $0.name == "CoachMessageReceipt" }) else { return [] }
        let q = FetchDescriptor<CoachMessageReceipt>(predicate: #Predicate { $0.expiresAt > now })
        let rows = ((try? context.fetch(q)) ?? []).filter { $0.eligible(at: now) }
        return rows.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func notification(_ id: UUID, in context: ModelContext) -> AppNotification? {
        var q = FetchDescriptor<AppNotification>(predicate: #Predicate { $0.id == id })
        q.fetchLimit = 1
        return (try? context.fetch(q))?.first
    }

    static func route(_ receipt: CoachMessageReceipt) -> NotificationRoute {
        receipt.routeRaw.flatMap(NotificationRoute.init(rawValue:))
            ?? NotificationRouteStore.route(for: receipt.id) ?? .coach
    }

    @discardableResult
    static func record(_ id: UUID, action: Action, in context: ModelContext, now: Date = Date(),
                       source: String = "coaching") -> Bool {
        guard let r = CoachMessageReceipt.fetch(id, in: context) else { return false }
        let fresh: Bool
        switch action {
        case .displayed: fresh = r.displayedAt == nil
        case .opened: fresh = r.openedAt == nil
        case .dismissed: fresh = r.dismissedAt == nil
        case .expired: fresh = r.expiredAt == nil
        }
        guard fresh else { return false }
        let note = notification(id, in: context)
        let old = (r.displayedAt, r.deliveredAt, r.openedAt, r.dismissedAt, r.expiredAt, note?.read)
        switch action {
        case .displayed: r.displayedAt = now; r.deliveredAt = r.deliveredAt ?? now
        case .opened:
            r.openedAt = now; r.displayedAt = r.displayedAt ?? now
            r.deliveredAt = r.deliveredAt ?? now
        case .dismissed: r.dismissedAt = now
        case .expired: r.expiredAt = now
        }
        if action != .expired { note?.read = true }
        do {
            // Reading a message must not run prescription-normalization engines.
            try context.save()
            AdaptiveAnalytics.emit("coach_message_" + action.rawValue, reason: source)
            cancelPush(id)
            return true
        } catch {
            r.displayedAt = old.0; r.deliveredAt = old.1; r.openedAt = old.2
            r.dismissedAt = old.3; r.expiredAt = old.4
            if let read = old.5 { note?.read = read }
            return false
        }
    }

    static func expire(in context: ModelContext, now: Date = Date()) {
        guard context.container.schema.entities.contains(where: { $0.name == "CoachMessageReceipt" }) else { return }
        let q = FetchDescriptor<CoachMessageReceipt>(predicate: #Predicate { $0.expiresAt <= now && $0.expiredAt == nil })
        for r in (try? context.fetch(q)) ?? [] { record(r.id, action: .expired, in: context, now: now) }
    }

    static func cancelPush(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        let key = "momentum.update.\(id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [key])
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }
}

/// Selection does not spend the allowance. Only an actual visible presentation does.
struct CoachOpeningBudget {
    private(set) var displayedID: UUID?
    var available: Bool { displayedID == nil }
    mutating func displayed(_ id: UUID) { if available { displayedID = id } }
    mutating func reset() { displayedID = nil }
}
