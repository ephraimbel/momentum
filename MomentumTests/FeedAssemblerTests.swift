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
}
