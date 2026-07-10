import Testing
import Foundation
@testable import Momentum

/// Feed assembly respects visibility and ordering (docs/SOCIAL-LAYER.md).
@MainActor
struct FeedAssemblerTests {
    private func workout(_ privacy: WorkoutPrivacy, daysAgo: Int) -> Workout {
        let w = Workout(); w.type = .run; w.privacy = privacy
        w.startedAt = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        return w
    }
    private let community = CommunityFeed.seed()

    @Test func privateWorkoutsNeverAppear() {
        let mine = [workout(.private, daysAgo: 0), workout(.private, daysAgo: 1)]
        let feed = FeedAssembler.feed(userWorkouts: mine, profile: UserProfile(), community: [])
        #expect(feed.isEmpty)
    }

    @Test func sharedWorkoutsAppearWithCommunity() {
        let mine = [workout(.public, daysAgo: 0), workout(.friends, daysAgo: 1), workout(.private, daysAgo: 2)]
        let feed = FeedAssembler.feed(userWorkouts: mine, profile: UserProfile(), community: community)
        let mineCount = feed.filter { !$0.isCommunity }.count
        #expect(mineCount == 2)                                   // public + friends, not private
        #expect(feed.contains { $0.isCommunity })                // community present
    }

    @Test func feedIsNewestFirst() {
        let mine = [workout(.public, daysAgo: 5), workout(.public, daysAgo: 0)]
        let feed = FeedAssembler.feed(userWorkouts: mine, profile: UserProfile(), community: [])
        #expect(feed.count == 2)
        #expect(feed[0].date > feed[1].date)
    }

    @Test func routeOnlyWhenOptedIn() {
        let w = workout(.public, daysAgo: 0)
        let g = GPSDetail()
        for i in 0..<5 {
            let s = LocationSample(); s.lat = 37.0 + Double(i) * 0.001; s.lon = -122.0 + Double(i) * 0.001
            s.t = w.startedAt.addingTimeInterval(Double(i)); s.accepted = true
            g.samples.append(s)
        }
        g.distanceM = 1000; w.gps = g

        let noRoute = UserProfile()                              // publicRouteMaps off
        #expect(FeedAssembler.item(from: w, profile: noRoute).routeLatLon == nil)

        let withRoute = UserProfile(); withRoute.publicRouteMaps = true
        let item = FeedAssembler.item(from: w, profile: withRoute)
        #expect(item.routeLatLon != nil && item.routeLatLon!.count == 5)
    }

    @Test func communitySeedIsLabeledAndStable() {
        #expect(!community.isEmpty)
        #expect(community.allSatisfy { $0.isCommunity })
        // Stable IDs across calls (deterministic feed).
        #expect(CommunityFeed.seed().map(\.id) == community.map(\.id))
    }

    @Test func strengthPostsCarryMuscleMap() {
        // Every strength/HIIT community post must light up a body (the lift counterpart to a route).
        let strength = community.filter { $0.type.isStrengthStyle }
        #expect(!strength.isEmpty)
        #expect(strength.allSatisfy { ($0.muscles?.isEmpty == false) })
        // Cardio posts never carry muscle data (they get a route map instead).
        #expect(community.filter { $0.type.isGPS }.allSatisfy { $0.muscles == nil })
    }

    @Test func titleDrivesWorkedMuscles() {
        #expect(StrengthFeedMuscles.activation(forTitle: "Push day", type: .strength).keys.contains(.chest))
        #expect(StrengthFeedMuscles.activation(forTitle: "Pull day", type: .strength).keys.contains(.back))
        #expect(StrengthFeedMuscles.activation(forTitle: "Leg day", type: .strength).keys.contains(.quads))
    }

    @Test func myStrengthWorkoutGetsMuscleMap() {
        let w = Workout(); w.type = .strength; w.privacy = .public; w.title = "Push day"
        let item = FeedAssembler.item(from: w, profile: UserProfile())
        #expect(item.muscles?.isEmpty == false)
    }

    // MARK: Following scope (CommunityView)

    @Test func followingScopeKeepsOwnPostsAndFollowedHandles() {
        let mine = [workout(.public, daysAgo: 0)]
        let feed = FeedAssembler.feed(userWorkouts: mine, profile: UserProfile(), community: community)
        guard let followedHandle = community.first?.authorHandle else {
            Issue.record("community seed has no handles"); return
        }
        let scoped = FeedAssembler.scoped(feed, following: [followedHandle])
        #expect(scoped.contains { !$0.isCommunity })                                  // own post kept
        #expect(scoped.filter(\.isCommunity).allSatisfy { $0.authorHandle == followedHandle })
        #expect(scoped.contains { $0.authorHandle == followedHandle })                // followed kept
    }

    @Test func followingScopeWithNoFollowsIsOwnPostsOnly() {
        let mine = [workout(.friends, daysAgo: 0)]
        let feed = FeedAssembler.feed(userWorkouts: mine, profile: UserProfile(), community: community)
        let scoped = FeedAssembler.scoped(feed, following: [])
        #expect(scoped.count == 1)
        #expect(!scoped[0].isCommunity)
    }

    @Test func followingScopePreservesNewestFirstOrder() {
        let feed = FeedAssembler.feed(userWorkouts: [], profile: UserProfile(), community: community)
        let following = Set(community.compactMap(\.authorHandle))
        let scoped = FeedAssembler.scoped(feed, following: following)
        #expect(scoped.count > 1)
        #expect(zip(scoped, scoped.dropFirst()).allSatisfy { $0.date >= $1.date })
    }

    @Test func privateWorkoutsNeverLeakIntoEitherScope() {
        let mine = [workout(.private, daysAgo: 0)]
        let feed = FeedAssembler.feed(userWorkouts: mine, profile: UserProfile(), community: community)
        #expect(!feed.contains { !$0.isCommunity })                                   // everyone scope
        #expect(!FeedAssembler.scoped(feed, following: []).contains { !$0.isCommunity })
    }
}
