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
    /// An attached coach card (encoded `CoachCardPayload`), rendered under the reply as a tappable
    /// proposal/nav card. nil = a plain text turn. Additive fields — lightweight migration.
    var cardJSON: String?
    var cardStateRaw: String?
    /// Full plan-state snapshot (`CoachUndo.Snapshot` JSON) captured just before this card's change
    /// was applied. Present only on the single most recent applied change — the one Undo can revert.
    var undoJSON: String?

    init(role: Role, text: String, createdAt: Date = Date(), card: CoachCardPayload? = nil) {
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
        if let card, card.kind != .none,
           let data = try? JSONEncoder().encode(card) {
            self.cardJSON = String(decoding: data, as: UTF8.self)
            self.cardStateRaw = CardState.proposed.rawValue
        }
    }

    enum Role: String, Sendable { case coach, user }
    var role: Role { Role(rawValue: roleRaw) ?? .coach }

    /// Lifecycle of an attached card. Proposals re-validate at tap time, so a stale card can only
    /// ever expire — it can never execute against a plan that changed underneath it. `undone` means
    /// the change was applied and then rolled back via the receipt's Undo.
    enum CardState: String, Sendable { case proposed, applied, declined, expired, undone }

    var card: CoachCardPayload? {
        get { cardJSON.flatMap { try? JSONDecoder().decode(CoachCardPayload.self, from: Data($0.utf8)) } }
        set {
            cardJSON = newValue.flatMap { try? JSONEncoder().encode($0) }
                .map { String(decoding: $0, as: UTF8.self) }
            if cardJSON != nil, cardStateRaw == nil { cardStateRaw = CardState.proposed.rawValue }
        }
    }

    var cardState: CardState? {
        get { cardStateRaw.flatMap(CardState.init(rawValue:)) }
        set { cardStateRaw = newValue?.rawValue }
    }
}
