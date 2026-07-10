import Testing
import Foundation
@testable import Momentum

/// Follow graph + community directory (docs/SOCIAL-LAYER.md, Slice 2).
@MainActor
struct SocialFollowTests {

    private func freshStore() -> (FollowStore, String) {
        let suite = "follow.test.\(UUID().uuidString)"
        return (FollowStore(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    @Test func toggleFollowsAndUnfollows() {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(!store.isFollowing("mayaruns"))
        store.toggle("mayaruns")
        #expect(store.isFollowing("mayaruns"))
        #expect(store.count == 1)
        store.toggle("mayaruns")
        #expect(!store.isFollowing("mayaruns"))
        #expect(store.count == 0)
    }

    @Test func followsPersistAcrossInstances() {
        let suite = "follow.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        FollowStore(defaults: defaults).toggle("coachtheo")
        #expect(FollowStore(defaults: defaults).isFollowing("coachtheo"))   // reloaded
    }

    @Test func emptyHandleIgnored() {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.toggle("")
        #expect(store.count == 0)
    }

    @Test func directoryLookupAndIntegrity() {
        let athletes = CommunityDirectory.all()
        #expect(athletes.count >= 5)
        #expect(CommunityDirectory.athlete(handle: "mayaruns")?.name == "Maya Rivera")
        #expect(CommunityDirectory.athlete(handle: "nobody") == nil)
        // Every seeded post belongs to a directory athlete (feed ↔ profile can't diverge).
        let handles = Set(athletes.map(\.handle))
        for post in CommunityFeed.seed() {
            #expect(post.authorHandle.map { handles.contains($0) } == true)
        }
    }
}
