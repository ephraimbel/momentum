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

    @Test func presenceStubReportsNoFabricatedCrowd() async {
        #expect(await StubPresenceService().refresh(appearOnMap: true) == 0)
        // Live service returns 0 until the Supabase realtime backend is configured (honest).
        #expect(await LivePresenceService().refresh(appearOnMap: true) == 0)
    }
}
