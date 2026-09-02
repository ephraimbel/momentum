import Foundation
import SwiftData
import Testing
@testable import Momentum

@MainActor
struct SocialActivityInboxTests {
    private final class Backend: StubSocialBackend {
        let activity: [SocialActivityHit]

        init(activity: [SocialActivityHit]) {
            self.activity = activity
        }

        override func pullSocialActivity(limit: Int) async -> [SocialActivityHit]? {
            Array(activity.prefix(limit))
        }
    }

    private func container() throws -> ModelContainer {
        let schema = Schema([AppNotification.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func realActivityCreatesDeepLinkedInboxRowsAndDedupes() async throws {
        let postID = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let hits = [
            SocialActivityHit(
                id: UUID(), kind: .respect, actorHandle: "mara",
                actorName: "Mara", postID: postID, postTitle: "Tempo Run",
                commentBody: nil, createdAt: date),
            SocialActivityHit(
                id: UUID(), kind: .comment, actorHandle: "eli",
                actorName: "Eli", postID: postID, postTitle: "Tempo Run",
                commentBody: "Strong finish.", createdAt: date.addingTimeInterval(1)),
            SocialActivityHit(
                id: UUID(), kind: .follow, actorHandle: "zoe",
                actorName: "Zoe", postID: nil, postTitle: nil,
                commentBody: nil, createdAt: date.addingTimeInterval(2))
        ]
        let backend = Backend(activity: hits)
        let container = try container()
        let context = container.mainContext

        await SocialActivityInbox.refresh(backend: backend, in: context, force: true)
        await SocialActivityInbox.refresh(backend: backend, in: context, force: true)

        let rows = try context.fetch(FetchDescriptor<AppNotification>())
        #expect(rows.count == 3)
        #expect(rows.first(where: { $0.kind == .respect })?.targetPostID == postID)
        #expect(rows.first(where: { $0.kind == .comment })?.body == "Strong finish.")
        #expect(rows.first(where: { $0.kind == .follow })?.targetHandle == "zoe")
        #expect(rows.first(where: { $0.kind == .follow })?.targetPostID == nil)
    }

    @Test func duplicateEventInsideOnePullCreatesOneInboxRow() async throws {
        let id = UUID()
        let hit = SocialActivityHit(
            id: id, kind: .respect, actorHandle: "mara",
            actorName: "Mara", postID: UUID(), postTitle: "Long Run",
            commentBody: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let backend = Backend(activity: [hit, hit])
        let container = try container()
        let context = container.mainContext

        await SocialActivityInbox.refresh(backend: backend, in: context, force: true)

        let rows = try context.fetch(FetchDescriptor<AppNotification>())
        #expect(rows.count == 1)
        #expect(rows.first?.dedupeToken == "social-\(id.uuidString)")
    }
}
