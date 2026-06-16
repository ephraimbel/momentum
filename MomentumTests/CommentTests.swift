import Testing
import Foundation
@testable import Momentum

/// Comments + light moderation (docs/SOCIAL-LAYER.md).
@MainActor
struct CommentTests {

    @Test func lightModerationTrimsCapsAndMasks() {
        #expect(CommentModeration.clean("  nice run  ") == "nice run")
        #expect(CommentModeration.clean("   ") == nil)               // empty → nothing to post
        #expect(CommentModeration.clean("") == nil)
        // Masks a crude word, leaves the rest (not strict).
        let cleaned = CommentModeration.clean("that is shit fast")
        #expect(cleaned == "that is •••• fast")
        // Length cap.
        let long = String(repeating: "a", count: 400)
        #expect(CommentModeration.clean(long)?.count == CommentModeration.maxLength)
    }

    @Test func addStoresAndPersistsUserComment() {
        let suite = "comments.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let post = UUID()
        let store = CommentStore(defaults: defaults)
        #expect(store.comments(for: post).isEmpty)

        let added = store.add("great session", to: post, authorName: "Me", authorHandle: "me")
        #expect(added != nil)
        #expect(store.comments(for: post).count == 1)
        #expect(store.add("   ", to: post, authorName: "Me", authorHandle: "me") == nil)  // empty ignored
        #expect(store.comments(for: post).count == 1)

        // Reloads from disk.
        #expect(CommentStore(defaults: defaults).comments(for: post).first?.text == "great session")
    }

    @Test func deleteRemovesUserComment() {
        let suite = "comments.del.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let post = UUID()
        let store = CommentStore(defaults: defaults)
        let c = store.add("oops", to: post, authorName: "Me", authorHandle: "me")!
        store.delete(c)
        #expect(store.comments(for: post).isEmpty)
    }

    @Test func seededCommunityCommentsAreStablePerPost() {
        let post = UUID()
        let a = CommunityComments.seed(for: post).map(\.text)
        let b = CommunityComments.seed(for: post).map(\.text)
        #expect(a == b)                                              // deterministic per post id
        #expect(CommunityComments.seed(for: post).allSatisfy { $0.isCommunity })
    }

    @Test func reportedCommentIsHidden() {
        let suite = "comments.mod.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mod = ModerationStore(defaults: defaults)
        let c = Comment(id: UUID(), postID: UUID(), authorName: "X", authorHandle: "x",
                        isCommunity: true, text: "hi", date: Date())
        #expect(mod.isVisible(c))
        mod.report(c.id)
        #expect(!mod.isVisible(c))
    }
}
