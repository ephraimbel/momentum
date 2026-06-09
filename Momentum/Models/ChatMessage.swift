import Foundation
import SwiftData

/// One turn in the AI coach conversation, persisted so the chat survives across launches (PRD §4.7).
/// A single ongoing thread, ordered by `createdAt`.
@Model
final class ChatMessage {
    var id: UUID = UUID()
    var roleRaw: String = Role.coach.rawValue
    var text: String = ""
    var createdAt: Date = Date()

    init(role: Role, text: String, createdAt: Date = Date()) {
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    enum Role: String, Sendable { case coach, user }
    var role: Role { Role(rawValue: roleRaw) ?? .coach }
}
