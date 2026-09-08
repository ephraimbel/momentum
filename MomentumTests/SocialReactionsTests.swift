import Testing
import Foundation
@testable import Momentum

/// Respect reactions + the presence seam (docs/SOCIAL-LAYER.md, Slice 4).
@MainActor
struct SocialReactionsTests {
    private func item(base: Int) -> FeedItem {
        FeedItem(id: UUID(), authorName: "A", authorHandle: "a", location: nil, isCommunity: true,
                 type: .run, date: Date(), title: "Run", caption: nil, statLine: "5 mi",
                 prBadge: nil, baseReactions: base)
    }
    private func freshStore() -> (ReactionStore, String) {
        let suite = "react.test.\(UUID().uuidString)"
        return (ReactionStore(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    @Test func toggleAddsViewerReactionOnTopOfBaseline() {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let post = item(base: 42)
        #expect(!store.hasReacted(post.id))
        #expect(store.count(for: post) == 42)
        store.toggle(post.id)
        #expect(store.hasReacted(post.id))
        #expect(store.count(for: post) == 43)        // viewer's real reaction adds one
        store.toggle(post.id)
        #expect(store.count(for: post) == 42)
    }

    @Test func reactionsPersist() {
        let suite = "react.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        ReactionStore(defaults: defaults).toggle(id)
        #expect(ReactionStore(defaults: defaults).hasReacted(id))   // reloaded
    }

    private final class DelayedReactionBackend: StubSocialBackend {
        var writes: [Bool] = []
        var reply: CheckedContinuation<Bool, Never>?
        override var isAvailable: Bool { true }
        override func setReaction(postID: UUID, reacted: Bool) async -> Bool {
            writes.append(reacted)
            return await withCheckedContinuation { reply = $0 }
        }
        func finish() {
            let continuation = reply
            reply = nil
            continuation?.resume(returning: true)
        }
    }

    @Test func rapidRetapAndRefreshSerializeTheLatestReaction() async {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let backend = DelayedReactionBackend()
        store.backend = backend
        let id = UUID()
        store.toggle(id)
        for _ in 0..<1000 where backend.reply == nil { await Task.yield() }
        #expect(backend.writes == [true])
        store.toggle(id)
        store.flushPending()
        for _ in 0..<100 { await Task.yield() }
        #expect(backend.writes == [true], "The un-react must wait for the first write")
        #expect(!store.hasReacted(id))
        backend.finish()
        for _ in 0..<1000 where backend.reply == nil { await Task.yield() }
        #expect(backend.writes == [true, false])
        #expect(store.pending.contains(id.uuidString), "The older response cannot acknowledge the new tap")
        backend.finish()
        for _ in 0..<1000 where !store.pending.isEmpty { await Task.yield() }
        #expect(store.pending.isEmpty)
        #expect(!store.hasReacted(id))
    }

    @Test func presenceStubReportsNoFabricatedCrowd() async {
        #expect(await StubPresenceService().refresh(appearOnMap: true) == 0)
        // Live service returns 0 until the Supabase realtime backend is configured (honest).
        #expect(await LivePresenceService().refresh(appearOnMap: true) == 0)
    }
}
