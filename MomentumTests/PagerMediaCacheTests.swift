import Testing
import Foundation
import CoreLocation
import UIKit
@testable import Momentum

/// The session caches behind the smooth pagers (2026-09-12): a recycled grid cell or pager page
/// must find its media synchronously on its first body pass, and none of the caches may grow
/// without bound while the athlete browses a long history.
@Suite(.serialized)
@MainActor
struct PagerMediaCacheTests {

    private func image(_ side: CGFloat, color: UIColor = .black) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    // MARK: WorkoutMediaCache

    @Test func resolvedMediaIsReadableSynchronouslyAndBounded() {
        WorkoutMediaCache.resetForTesting()
        defer { WorkoutMediaCache.resetForTesting() }
        #expect(WorkoutMediaCache.cached("a") == nil)

        WorkoutMediaCache.store(.snapshot(image(10)), key: "a")
        WorkoutMediaCache.store(.glyph, key: "b")
        guard case .snapshot? = WorkoutMediaCache.cached("a") else {
            Issue.record("a stored snapshot must read back on the next frame"); return
        }
        guard case .glyph? = WorkoutMediaCache.cached("b") else {
            Issue.record("the glyph marker must read back too"); return
        }

        // Entry budget: oldest-touched first. Touch "a" so "b" is the stalest.
        _ = WorkoutMediaCache.cached("a")
        for i in 0..<WorkoutMediaCache.entryBudget {
            WorkoutMediaCache.store(.glyph, key: "fill-\(i)")
        }
        #expect(WorkoutMediaCache.residentCount <= WorkoutMediaCache.entryBudget)
        #expect(WorkoutMediaCache.cached("b") == nil, "the least recently used entry leaves first")
    }

    @Test func imageBytesAreBudgetedByDecodedSize() {
        WorkoutMediaCache.resetForTesting()
        defer { WorkoutMediaCache.resetForTesting() }
        // Each 1000×1000 @1x image is ~4 MB decoded; the budget admits ~16 before evicting.
        let perImage = 1000 * 1000 * 4
        let fits = WorkoutMediaCache.byteBudget / perImage
        for i in 0..<(fits + 6) {
            WorkoutMediaCache.store(.photo(image(1000)), key: "photo-\(i)")
        }
        #expect(WorkoutMediaCache.residentBytes <= WorkoutMediaCache.byteBudget)
        #expect(WorkoutMediaCache.residentCount < fits + 6)
        #expect(WorkoutMediaCache.cached("photo-0") == nil, "the oldest photo is gone")
        #expect(WorkoutMediaCache.cached("photo-\(fits + 5)") != nil, "the newest photo stays")

        WorkoutMediaCache.purge()
        #expect(WorkoutMediaCache.residentCount == 0)
        #expect(WorkoutMediaCache.residentBytes == 0)
    }

    // MARK: RouteCoordinateCache

    private func transientRun(points: Int) -> Workout {
        let run = Workout()
        run.type = .run
        let gps = GPSDetail()
        let t0 = Date()
        for i in 0..<points {
            let s = LocationSample()
            s.t = t0.addingTimeInterval(Double(i) * 3)
            s.lat = 30.27 + Double(i) * 0.00004
            s.lon = -97.74 + Double(i) * 0.00002
            s.accuracyM = 5
            s.speedMS = 3
            s.accepted = true
            gps.samples.append(s)
        }
        run.gps = gps
        return run
    }

    @Test func routeIsComputedOnceThenReadSynchronously() async {
        RouteCoordinateCache.resetForTesting()
        defer { RouteCoordinateCache.resetForTesting() }
        let run = transientRun(points: 40)
        #expect(RouteCoordinateCache.cached(run.id) == nil, "nothing is in hand before the first walk")

        let first = await RouteCoordinateCache.coordinates(for: run)
        #expect(first.count > 40, "the route the live map draws is the splined one")
        let sync = RouteCoordinateCache.cached(run.id)
        #expect(sync?.count == first.count, "the same array reads back with no await")

        // Two callers at once (the page and the pager's prefetch) share one walk.
        let other = transientRun(points: 30)
        async let a = RouteCoordinateCache.coordinates(for: other)
        async let b = RouteCoordinateCache.coordinates(for: other)
        let (ra, rb) = await (a, b)
        #expect(ra.count == rb.count && ra.count > 30)
        #expect(RouteCoordinateCache.residentCount == 2)
    }

    @Test func routeCacheEvictsOldestBeyondItsBudget() async {
        RouteCoordinateCache.resetForTesting()
        defer { RouteCoordinateCache.resetForTesting() }
        var ids: [UUID] = []
        for _ in 0..<(RouteCoordinateCache.entryBudget + 3) {
            let run = transientRun(points: 4)
            ids.append(run.id)
            _ = await RouteCoordinateCache.coordinates(for: run)
        }
        #expect(RouteCoordinateCache.residentCount == RouteCoordinateCache.entryBudget)
        #expect(RouteCoordinateCache.cached(ids[0]) == nil, "the first route walked is the first evicted")
        #expect(RouteCoordinateCache.cached(ids[ids.count - 1]) != nil)
    }

    @Test func runWithoutSamplesYieldsNoRouteAndCachesNothing() async {
        RouteCoordinateCache.resetForTesting()
        defer { RouteCoordinateCache.resetForTesting() }
        let empty = transientRun(points: 0)
        let coords = await RouteCoordinateCache.coordinates(for: empty)
        #expect(coords.isEmpty)
        #expect(RouteCoordinateCache.cached(empty.id) == nil)
    }

    // MARK: ImageDownsampler

    @Test func decodedPhotosAreProbeableWithoutAnAwait() async {
        // A byte-identical blob would collide with an earlier run's key, so the fill is random.
        let unique = image(64, color: UIColor(hue: .random(in: 0...1), saturation: 0.7,
                                              brightness: 0.8, alpha: 1)).pngData()!
        #expect(ImageDownsampler.cached(unique, maxPixel: 480) == nil,
                "before the decode there is nothing to read")
        let decoded = await ImageDownsampler.thumbnail(unique, maxPixel: 480)
        #expect(decoded != nil)
        #expect(ImageDownsampler.cached(unique, maxPixel: 480) != nil, "after it, the frame-one read hits")
        #expect(ImageDownsampler.cached(unique, maxPixel: 1400) == nil, "a different size is a different key")
    }
}
