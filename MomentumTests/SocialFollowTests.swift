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

    // MARK: Merge — what a server pull may and may not undo

    @Test func mergeKeepsSeededFollowsAndAdoptsRemote() {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.toggle("mayaruns")                     // seeded: no server profile, ever
        store.merge(remote: ["realathlete"])         // server knows a different, real follow
        #expect(store.isFollowing("mayaruns"))       // survives the pull
        #expect(store.isFollowing("realathlete"))    // adopted from the pull
        #expect(store.count == 2)
    }

    /// The silent-loss case: a follow made while the push couldn't land must not be pruned by the
    /// first successful pull that doesn't list it yet.
    @Test func mergeKeepsAnUnpushedRealFollow() {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.backend = FailingFollowBackend()        // every push fails (offline/guest)
        store.toggle("realathlete")
        store.merge(remote: [])                      // server answers, hasn't seen it
        #expect(store.isFollowing("realathlete"))
        #expect(store.pending.contains("realathlete"))
    }

    /// The mirror case: an unfollow the server hasn't taken yet isn't resurrected by the pull.
    @Test func mergeDoesNotResurrectAnUnpushedUnfollow() {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.backend = FailingFollowBackend()
        store.merge(remote: ["realathlete"])         // server says we follow them
        #expect(store.isFollowing("realathlete"))
        store.toggle("realathlete")                  // we unfollow; push fails
        store.merge(remote: ["realathlete"])         // server still lists them
        #expect(!store.isFollowing("realathlete"))
    }

    /// Seeded community athletes have no server profile, so their pushes can never succeed —
    /// marking them pending would retry a futile lookup on every feed refresh, forever. They're
    /// protected by the seeded-follow rule instead.
    @Test func seededFollowsAreNeverPending() {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.backend = FailingFollowBackend()
        store.toggle("mayaruns")                     // in the community directory
        #expect(store.pending.isEmpty)
        store.merge(remote: [])
        #expect(store.isFollowing("mayaruns"))       // still protected across a pull
    }

    /// A confirmed push clears the pending flag, so the server becomes authoritative again.
    @Test func confirmedPushClearsPending() async {
        let (store, suite) = freshStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.backend = ConfirmingFollowBackend()
        store.toggle("realathlete")
        // `toggle` fires the push in a detached task; yield until it settles.
        for _ in 0..<50 where !store.pending.isEmpty { await Task.yield() }
        #expect(store.pending.isEmpty)
        #expect(store.isFollowing("realathlete"))
    }

    @Test func pendingSurvivesRelaunch() {
        let suite = "follow.pending.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FollowStore(defaults: defaults)
        first.backend = FailingFollowBackend()
        first.toggle("realathlete")
        // Reloaded (cold launch): the unpushed intent is still known, so a pull can't prune it.
        let second = FollowStore(defaults: defaults)
        #expect(second.pending.contains("realathlete"))
        second.merge(remote: [])
        #expect(second.isFollowing("realathlete"))
    }

    // MARK: The seeded community's graph — a real graph, or the tap-through breaks

    /// The bar (owner, 2026-07-30): open any follower of X → open THEIR following → X is there.
    /// Reciprocal by construction (one edge function), pinned so a refactor back to independent
    /// per-profile draws can't ship.
    @Test func communityGraphIsReciprocal() {
        let athletes = Array(CommunityDirectory.all().prefix(12))
        for athlete in athletes {
            for follower in CommunityGraph.followerHandles(of: athlete.handle).prefix(5) {
                #expect(CommunityGraph.followingHandles(of: follower).contains(athlete.handle),
                        "\(follower) appears in \(athlete.handle)'s followers but doesn't follow them back-consistently")
            }
            for followee in CommunityGraph.followingHandles(of: athlete.handle).prefix(5) {
                #expect(CommunityGraph.followerHandles(of: followee).contains(athlete.handle))
            }
        }
    }

    /// Header numbers ARE the lists' counts, nobody follows themselves, and the emergent counts
    /// stay in a lively-but-plausible band (a page of 0-follower athletes reads dead; thousands
    /// reads planted).
    @Test func communityGraphCountsAreConsistentAndPlausible() {
        for athlete in CommunityDirectory.all().prefix(20) {
            let followers = CommunityGraph.followerHandles(of: athlete.handle)
            let following = CommunityGraph.followingHandles(of: athlete.handle)
            #expect(athlete.sampleFollowerCount == followers.count)
            #expect(athlete.sampleFollowingCount == following.count)
            #expect(!followers.contains(athlete.handle))
            #expect(!following.contains(athlete.handle))
            #expect(followers.count == Set(followers).count)   // no duplicate rows
            #expect((3...600).contains(followers.count), "followers \(followers.count) out of band")
            #expect((3...600).contains(following.count), "following \(following.count) out of band")
        }
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

// MARK: - Backend spies (subclass the stub; override only the call under test)

/// Every follow push fails — a guest, an unreachable server, or an unresolvable handle.
@MainActor
private final class FailingFollowBackend: StubSocialBackend {
    override func setFollow(handle: String, following: Bool) async -> Bool { false }
}

/// Every follow push lands.
@MainActor
private final class ConfirmingFollowBackend: StubSocialBackend {
    override func setFollow(handle: String, following: Bool) async -> Bool { true }
}
