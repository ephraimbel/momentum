import Foundation
import Testing
@testable import Momentum

@MainActor
struct CommunityExperienceStoreTests {
    private func defaults() -> UserDefaults {
        let name = "CommunityExperienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func item(_ id: UUID = UUID(), at date: Date) -> FeedItem {
        FeedItem(
            id: id,
            authorName: "Athlete",
            authorHandle: "athlete",
            location: nil,
            isCommunity: true,
            type: .run,
            date: date,
            title: "Morning Run",
            caption: nil,
            statLine: "5.0 km · 25:00",
            prBadge: nil)
    }

    @Test func firstVisitDoesNotManufactureNewPosts() {
        let store = CommunityExperienceStore(defaults: defaults())
        let feed = [item(at: Date()), item(at: Date().addingTimeInterval(-60))]

        let visit = store.visit(items: feed, scope: .everyone)

        #expect(visit.restoreID == nil)
        #expect(visit.boundaryID == nil)
        #expect(visit.newCount == 0)
    }

    @Test func returningVisitRestoresExactPositionAndMarksTheFirstSeenPost() {
        let store = CommunityExperienceStore(defaults: defaults())
        let oldNewest = item(at: Date(timeIntervalSince1970: 1_000))
        let anchor = item(at: Date(timeIntervalSince1970: 900))
        store.saveAnchor(anchor, scope: .everyone)
        store.finishVisit(items: [oldNewest, anchor], scope: .everyone)

        let newOne = item(at: Date(timeIntervalSince1970: 1_200))
        let newTwo = item(at: Date(timeIntervalSince1970: 1_100))
        let visit = store.visit(items: [newOne, newTwo, oldNewest, anchor], scope: .everyone)

        #expect(visit.restoreID == anchor.id)
        #expect(visit.boundaryID == oldNewest.id)
        #expect(visit.newCount == 2)
    }

    @Test func deletedAnchorFallsBackToTheClosestOlderPost() {
        let store = CommunityExperienceStore(defaults: defaults())
        let deleted = item(at: Date(timeIntervalSince1970: 900))
        store.saveAnchor(deleted, scope: .following)

        let newer = item(at: Date(timeIntervalSince1970: 950))
        let closestOlder = item(at: Date(timeIntervalSince1970: 890))
        let older = item(at: Date(timeIntervalSince1970: 800))
        let visit = store.visit(items: [newer, closestOlder, older], scope: .following)

        #expect(visit.restoreID == closestOlder.id)
    }

    @Test func everyRouteGetsOneRevealPerPagerVisit() {
        let first = UUID()
        let second = UUID()
        var visit = CommunityRouteRevealState()

        let activatedFirst = visit.activate(first)
        #expect(activatedFirst)
        #expect(visit.shouldAnimate(first))
        let activatedSecond = visit.activate(second)
        #expect(activatedSecond)
        #expect(visit.shouldAnimate(second))

        visit.complete(first)
        #expect(!visit.shouldAnimate(first))
        #expect(visit.shouldAnimate(second), "finishing one post must not suppress another")
        let restartedFirst = visit.activate(first)
        #expect(!restartedFirst, "a recycled page must not restart in the same pager")

        var nextVisit = CommunityRouteRevealState()
        let activatedOnNextVisit = nextVisit.activate(first)
        #expect(activatedOnNextVisit)
        #expect(nextVisit.shouldAnimate(first), "opening the post later should animate again")
    }

    @Test func malformedRemoteRoutesCannotCrashCommunitySurfaces() throws {
        var post = item(at: Date())
        post.routeLatLon = [
            [], [30.2], [Double.nan, -97.7], [91, -97.7], [30.2, -181],
            [30.20, -97.70], [30.20, -97.70], [30.21, -97.71]
        ]

        #expect(post.hasRenderableRoute)
        let coordinates = try #require(post.routeCoordinates)
        #expect(coordinates.count == 2)
        #expect(post.sanitizedRouteLatLon == [[30.20, -97.70], [30.21, -97.71]])
    }

    @Test func routeWithoutAValidSegmentDegradesToRoutelessPost() {
        var post = item(at: Date())
        post.routeLatLon = [[], [30.2], [Double.infinity, -97.7], [30.2, -97.7], [30.2, -97.7]]

        #expect(!post.hasRenderableRoute)
        #expect(post.routeCoordinates == nil)
        #expect(post.sanitizedRouteLatLon == nil)
    }
}
