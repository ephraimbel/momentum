import Foundation
import SwiftData

@Model
final class CoachMessageReceipt {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var expiresAt: Date
    var deliveredAt: Date?
    var displayedAt: Date?
    var openedAt: Date?
    var dismissedAt: Date?
    var expiredAt: Date?
    var pushScheduledAt: Date?
    var priority: Int = 30
    var routeRaw: String?
    var topic: String?
    init(id: UUID, now: Date) {
        self.id = id; createdAt = now; expiresAt = now.addingTimeInterval(7 * 86_400)
    }
    func eligible(at now: Date) -> Bool {
        expiresAt > now && expiredAt == nil && displayedAt == nil && openedAt == nil && dismissedAt == nil
    }
    static func fetch(_ id: UUID, in context: ModelContext) -> CoachMessageReceipt? {
        guard context.container.schema.entities.contains(where: { $0.name == "CoachMessageReceipt" }) else { return nil }
        var q = FetchDescriptor<CoachMessageReceipt>(predicate: #Predicate { $0.id == id })
        q.fetchLimit = 1
        return (try? context.fetch(q))?.first
    }
}
