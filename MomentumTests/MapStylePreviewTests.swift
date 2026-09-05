import Testing
import SwiftUI
import CoreLocation
import MapboxMaps
@testable import Momentum

@MainActor
struct MapStylePreviewTests {
    private func request(_ option: MapStyleOption = .realistic, scheme: ColorScheme = .light,
                         latitude: Double = 30.2672, longitude: Double = -97.7431,
                         size: CGSize = CGSize(width: 220, height: 165), scale: CGFloat = 3) -> MapStylePreviewRequest {
        MapStylePreviewRequest(option: option, center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                               scheme: scheme, size: size, scale: scale)
    }

    @Test func onlyAdaptiveDefaultChangesWithAppearance() {
        #expect(MapStyleOption.realistic.renderedStyle(for: .dark) == .night)
        for option in MapStyleOption.pickable where option != .realistic {
            #expect(option.renderedStyle(for: .dark) == option)
            #expect(option.renderedStyle(for: .light) == option)
        }
        #expect(request(scheme: .dark).option == .night)
        #expect(request(scheme: .dark).pitch == MapStyleOption.realistic.explorePitch)
        #expect(request(scheme: .dark).key != request().key)
    }

    @Test func keysIncludeAreaSizeAndScaleButIgnoreTinyDrift() {
        #expect(request() == request(latitude: 30.2673, longitude: -97.7432))
        #expect(request().key != request(latitude: 31).key)
        #expect(request().key != request(size: CGSize(width: 240, height: 180)).key)
        #expect(request().key != request(scale: 2).key)
        #expect(Set(MapStyleOption.pickable.map { request($0).key }).count == 9)
    }

    @Test func invalidCoordinatesAndExtremeGeometryCannotCrashPreview() {
        let invalid = request(latitude: .nan, longitude: .infinity,
                              size: CGSize(width: CGFloat.infinity, height: -1), scale: .nan)
        #expect(CLLocationCoordinate2DIsValid(invalid.center))
        #expect(invalid.width == 220)
        #expect(invalid.height == 44)
        #expect(invalid.scale == 2)
        #expect(CLLocationCoordinate2DIsValid(request(latitude: 90, longitude: 180).center))
    }

    @Test func entitlementLapseKeepsFreeStylesAndNormalizesProStyles() {
        for option in MapStyleOption.pickable {
            #expect(option.availableStyle(hasPro: true) == option)
            #expect(option.availableStyle(hasPro: false) == (option.requiresPro ? .realistic : option))
        }
    }

    private var pannedCamera: CameraState {
        CameraState(center: CLLocationCoordinate2D(latitude: 37.8, longitude: -122.4),
                    padding: .zero, zoom: 16.2, bearing: 32, pitch: 0)
    }

    @Test func styleSwitchPreservesThePannedCameraWithoutResumingFollow() {
        let target = MapStyleCamera.retilted(.idle, camera: pannedCamera, pitch: 45, authorized: true)
        #expect(target.followPuck == nil)
        #expect(target.camera?.center?.latitude == pannedCamera.center.latitude)
        #expect(target.camera?.center?.longitude == pannedCamera.center.longitude)
        #expect(target.camera?.zoom == pannedCamera.zoom)
        #expect(target.camera?.bearing == pannedCamera.bearing)
        #expect(target.camera?.pitch == 45)
    }

    @Test func styleSwitchPreservesAnExistingAuthorizedFollowMode() {
        let previous = Viewport.followPuck(zoom: 15, bearing: .heading, pitch: 0)
        let target = MapStyleCamera.retilted(previous, camera: pannedCamera, pitch: 45, authorized: true)
        #expect(target.followPuck?.zoom == pannedCamera.zoom)
        #expect(target.followPuck?.bearing == .heading)
        #expect(target.followPuck?.pitch == 45)
    }

    @Test func styleSwitchNeverStartsLocationFollowingWithoutPermission() {
        let previous = Viewport.followPuck(zoom: 15, pitch: 0)
        let target = MapStyleCamera.retilted(previous, camera: pannedCamera, pitch: 0, authorized: false)
        #expect(target.followPuck == nil)
        #expect(target.camera?.center?.latitude == pannedCamera.center.latitude)
    }

    @Test func rendersAreBoundedAndQueuedRequestsEventuallyComplete() async {
        let renderer = ControlledRenderer()
        let pipeline = MapStylePreviewPipeline(limit: 2) { await renderer.load($0) }
        let first = Task { await pipeline.image(for: request()) }
        let second = Task { await pipeline.image(for: request(.dusk)) }
        let third = Task { await pipeline.image(for: request(.streets)) }
        await until { pipeline.subscriberCount == 3 && renderer.requests.count == 2 }
        #expect(renderer.requests.count == 2)
        renderer.complete(0)
        await until { renderer.requests.count == 3 }
        renderer.complete(1)
        renderer.complete(2)
        #expect(await first.value != nil)
        #expect(await second.value != nil)
        #expect(await third.value != nil)
        #expect(pipeline.subscriberCount == 0)
    }

    @Test func sharedWorkSurvivesOneCancellationAndThenHitsMemoryCache() async {
        let renderer = ControlledRenderer()
        let pipeline = MapStylePreviewPipeline(limit: 2) { await renderer.load($0) }
        let first = Task { await pipeline.image(for: request()) }
        let second = Task { await pipeline.image(for: request()) }
        await until { pipeline.subscriberCount == 2 && renderer.requests.count == 1 }
        first.cancel()
        #expect(await first.value == nil)
        let expected = UIImage()
        renderer.complete(0, image: expected)
        #expect(await second.value === expected)
        #expect(await pipeline.image(for: request()) === expected)
        #expect(renderer.requests.count == 1)
    }

    @Test func cancelledQueuedWorkNeverStarts() async {
        let renderer = ControlledRenderer()
        let pipeline = MapStylePreviewPipeline(limit: 1) { await renderer.load($0) }
        let first = Task { await pipeline.image(for: request()) }
        await until { renderer.requests.count == 1 }
        let queued = Task { await pipeline.image(for: request(.dusk)) }
        await until { pipeline.subscriberCount == 2 }
        queued.cancel()
        #expect(await queued.value == nil)
        renderer.complete(0)
        _ = await first.value
        #expect(renderer.requests.count == 1)
        #expect(pipeline.subscriberCount == 0)
    }

    @Test func lateCancelledResultCannotOverwriteAReopenedRequest() async {
        let renderer = ControlledRenderer()
        let pipeline = MapStylePreviewPipeline(limit: 2) { await renderer.load($0) }
        let first = Task { await pipeline.image(for: request()) }
        await until { renderer.requests.count == 1 }
        first.cancel()
        #expect(await first.value == nil)
        let reopened = Task { await pipeline.image(for: request()) }
        await until { renderer.requests.count == 2 }
        renderer.complete(0)
        let expected = UIImage()
        renderer.complete(1, image: expected)
        #expect(await reopened.value === expected)
        #expect(await pipeline.image(for: request()) === expected)
    }

    @Test func failedPreviewCanRetryInsteadOfCachingFailureForever() async {
        var attempts = 0
        let pipeline = MapStylePreviewPipeline(limit: 2) { _ in
            attempts += 1
            return attempts == 1 ? nil : UIImage()
        }
        #expect(await pipeline.image(for: request()) == nil)
        #expect(await pipeline.image(for: request()) != nil)
        #expect(attempts == 2)
    }

    private func until(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(predicate(), "Preview pipeline did not reach the expected state")
    }

    @MainActor private final class ControlledRenderer {
        var requests: [MapStylePreviewRequest] = []
        private var continuations: [Int: CheckedContinuation<UIImage?, Never>] = [:]
        func load(_ request: MapStylePreviewRequest) async -> UIImage? {
            await withCheckedContinuation { continuation in
                continuations[requests.count] = continuation
                requests.append(request)
            }
        }
        func complete(_ index: Int, image: UIImage? = UIImage()) {
            continuations.removeValue(forKey: index)?.resume(returning: image)
        }
    }
}
