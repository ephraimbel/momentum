import Foundation
import SwiftData

/// An in-app notification the athlete received from momentum — a workout reminder, a coaching nudge, a
/// streak alert, an achievement. Every push the app surfaces is also recorded here so the bell opens a
/// real inbox of everything, not a dead icon. Read state drives the unread badge.
@Model
final class AppNotification {
    enum Kind: String, Codable, Sendable {
        case reminder, coaching, streak, achievement, system
        /// A mutual nudged you (social, 2026-08-25).
        case nudge
        /// Genuine backend activity on the athlete's public social projection.
        case respect, comment, follow

        var systemImage: String {
            switch self {
            case .reminder: "bell.fill"
            case .coaching: "figure.run"
            case .streak: "flame.fill"
            case .achievement: "trophy.fill"
            case .system: "sparkles"
            case .nudge: "hand.wave.fill"
            case .respect: "heart.fill"
            case .comment: "bubble.left.fill"
            case .follow: "person.badge.plus"
            }
        }
    }

    var id: UUID = UUID()
    var date: Date = Date()
    var kindRaw: String = Kind.system.rawValue
    var title: String = ""
    var body: String = ""
    var read: Bool = false
    /// Optional key to avoid re-posting the same notification (e.g. one workout reminder per day).
    var dedupeToken: String?
    /// Optional social deep-link payload. Nil for coaching/system notifications and for legacy rows.
    var targetPostID: UUID?
    var targetHandle: String?

    var kind: Kind { Kind(rawValue: kindRaw) ?? .system }

    init(kind: Kind, title: String, body: String, date: Date, dedupeToken: String? = nil,
         targetPostID: UUID? = nil, targetHandle: String? = nil) {
        self.kindRaw = kind.rawValue
        self.title = title
        self.body = body
        self.date = date
        self.dedupeToken = dedupeToken
        self.targetPostID = targetPostID
        self.targetHandle = targetHandle
    }

    /// Record a notification in the inbox. When `dedupeToken` is set, skips if one with that token was
    /// already posted the same day — so a daily reminder or a one-off welcome never stacks up.
    static func post(kind: Kind, title: String, body: String, on date: Date = Date(),
                     in context: ModelContext, dedupeToken: String? = nil, daily: Bool = true,
                     targetPostID: UUID? = nil, targetHandle: String? = nil,
                     calendar: Calendar = .current) {
        if let token = dedupeToken {
            let existing = (try? context.fetch(FetchDescriptor<AppNotification>())) ?? []
            // `daily` → one per day; otherwise once ever (a welcome shouldn't reappear tomorrow).
            if existing.contains(where: { $0.dedupeToken == token && (!daily || calendar.isDate($0.date, inSameDayAs: date)) }) { return }
        }
        context.insert(AppNotification(kind: kind, title: title, body: body, date: date,
                                       dedupeToken: dedupeToken, targetPostID: targetPostID,
                                       targetHandle: targetHandle))
        try? context.save()
    }
}
