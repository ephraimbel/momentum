import Testing
import Foundation
import CoreLocation
@testable import Momentum

@Suite(.serialized)
@MainActor
struct CommunitySnapshotQueueTests {
    @Test func cancelledOffscreenTilesDoNotKeepAColdRenderBacklog() async {
        var started = 0
        var releases: [CheckedContinuation<Void, Never>] = []
        FeedRouteSnapshots.renderForTesting = { _ in
            started += 1
            await withCheckedContinuation { releases.append($0) }
            return nil
        }
        defer { FeedRouteSnapshots.renderForTesting = nil }
        let tasks = (0..<20).map { _ in
            Task { @MainActor in
                await FeedRouteSnapshots.image(post: UUID(), coordinates: [
                    CLLocationCoordinate2D(latitude: 40, longitude: -74),
                    CLLocationCoordinate2D(latitude: 40.01, longitude: -74.01)
                ], style: .standard, scheme: .light, size: CGSize(width: 100, height: 100))
            }
        }
        for _ in 0..<100 where started < 4 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(started == 4, "Only four background render engines may be active")
        tasks.forEach { $0.cancel() }
        for task in tasks { #expect(await task.value == nil) }
        releases.forEach { $0.resume() }
        for _ in 0..<100 where FeedRouteSnapshots.pendingRenderCount > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(started == 4, "The sixteen cancelled queued tiles must never start an engine")
        #expect(FeedRouteSnapshots.pendingRenderCount == 0)
    }
    @Test func scrollingPausesBackgroundMapsButAllowsOpenedPosts() async {
        let first = UUID(), second = UUID()
        var started = 0
        FeedRouteSnapshots.renderForTesting = { _ in started += 1; return nil }
        FeedRouteSnapshots.setScrolling(true, source: first)
        FeedRouteSnapshots.setScrolling(true, source: second)
        defer {
            FeedRouteSnapshots.setScrolling(false, source: first)
            FeedRouteSnapshots.setScrolling(false, source: second)
            FeedRouteSnapshots.renderForTesting = nil
        }
        let coordinates = [CLLocationCoordinate2D(latitude: 40, longitude: -74),
                           CLLocationCoordinate2D(latitude: 40.01, longitude: -74.01)]
        let background = Task { @MainActor in
            await FeedRouteSnapshots.image(post: UUID(), coordinates: coordinates,
                style: .standard, scheme: .light, size: CGSize(width: 100, height: 100))
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(started == 0)
        _ = await FeedRouteSnapshots.image(post: UUID(), coordinates: coordinates,
            style: .standard, scheme: .light, size: CGSize(width: 200, height: 400), urgent: true)
        #expect(started == 1)
        FeedRouteSnapshots.setScrolling(false, source: first)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(started == 1, "Another scrolling surface still owns the pause")
        FeedRouteSnapshots.setScrolling(false, source: second)
        _ = await background.value
        #expect(started == 2)
        #expect(FeedRouteSnapshots.pendingRenderCount == 0)
    }

    @Test func openedPostPromotesItsAlreadyQueuedPrefetch() async {
        let source = UUID(), post = UUID()
        let size = CGSize(width: 200, height: 400)
        let coordinates = [CLLocationCoordinate2D(latitude: 40, longitude: -74),
                           CLLocationCoordinate2D(latitude: 40.01, longitude: -74.01)]
        var started = 0
        FeedRouteSnapshots.renderForTesting = { _ in started += 1; return nil }
        FeedRouteSnapshots.setScrolling(true, source: source)
        defer {
            FeedRouteSnapshots.setScrolling(false, source: source)
            FeedRouteSnapshots.renderForTesting = nil
        }
        let prefetch = Task { @MainActor in
            await FeedRouteSnapshots.image(post: post, coordinates: coordinates,
                style: .standard, scheme: .light, size: size)
        }
        try? await Task.sleep(for: .milliseconds(150))
        let opened = Task { @MainActor in
            await FeedRouteSnapshots.image(post: post, coordinates: coordinates,
                style: .standard, scheme: .light, size: size, urgent: true)
        }
        for _ in 0..<50 where started == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(started == 1, "Opening a prefetched post must promote the same queued render")
        // Release even on failure so a regression reports an assertion instead of hanging tests.
        FeedRouteSnapshots.setScrolling(false, source: source)
        _ = await prefetch.value
        _ = await opened.value
        #expect(started == 1, "Both callers share one render")
    }

}
