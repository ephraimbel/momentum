import Foundation
import SwiftData

/// One real server-side interaction directed at the signed-in athlete. Sample community activity
/// never enters this type; the backend only emits rows created by authenticated people.
struct SocialActivityHit: Sendable, Identifiable {
    enum Kind: String, Sendable { case respect, comment, follow }

    let id: UUID
    let kind: Kind
    let actorHandle: String
    let actorName: String
    let postID: UUID?
    let postTitle: String?
    let commentBody: String?
    let createdAt: Date
}

/// Bridges backend activity into the existing bell inbox. Pulls are intentionally repeatable:
/// `AppNotification` dedupes by immutable event id, so every device can build the same inbox and a
/// crash between network and local save loses nothing.
@MainActor
enum SocialActivityInbox {
    private static var lastPull = Date.distantPast

    static func refresh(backend: any SocialBackending, in context: ModelContext,
                        force: Bool = false, now: Date = Date()) async {
        guard force || now.timeIntervalSince(lastPull) > 45 else { return }
        lastPull = now
        guard let hits = await backend.pullSocialActivity(limit: 100), !hits.isEmpty else { return }

        // Fetch once and save once. Calling AppNotification.post for every hit fetched the whole
        // inbox and committed the ModelContext up to 100 times on the main actor — quadratic work
        // exactly when the athlete opens Community. Event ids are immutable, so one in-memory set
        // preserves the same once-ever dedupe contract for both persisted and same-page rows.
        let existing = (try? context.fetch(FetchDescriptor<AppNotification>())) ?? []
        var dedupeTokens = Set(existing.compactMap(\.dedupeToken))
        var inserted = false
        for hit in hits {
            let token = "social-\(hit.id.uuidString)"
            guard dedupeTokens.insert(token).inserted else { continue }
            let who = hit.actorName.isEmpty ? "@\(hit.actorHandle)" : hit.actorName
            let post = (hit.postTitle?.isEmpty == false ? hit.postTitle! : "workout")
            let notification: AppNotification
            switch hit.kind {
            case .respect:
                notification = AppNotification(
                    kind: .respect, title: "\(who) respected your \(post)",
                    body: "Open the workout to see the conversation.", date: hit.createdAt,
                    dedupeToken: token,
                    targetPostID: hit.postID, targetHandle: hit.actorHandle)
            case .comment:
                let text = hit.commentBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                notification = AppNotification(
                    kind: .comment, title: "\(who) commented on your \(post)",
                    body: text.isEmpty ? "Open the workout to read it." : text,
                    date: hit.createdAt, dedupeToken: token,
                    targetPostID: hit.postID, targetHandle: hit.actorHandle)
            case .follow:
                notification = AppNotification(
                    kind: .follow, title: "\(who) followed you",
                    body: "View their public training profile.", date: hit.createdAt,
                    dedupeToken: token,
                    targetHandle: hit.actorHandle)
            }
            context.insert(notification)
            inserted = true
        }
        if inserted { try? context.save() }
    }
}
