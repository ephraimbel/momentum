import SwiftUI
import CoreLocation
import MapboxMaps

/// Cache identity includes the actual lighting, area, dimensions and scale. Quantization keeps
/// ordinary GPS drift from making nine new renders; invalid coordinates never reach Mapbox.
struct MapStylePreviewRequest: Hashable, Sendable {
    let option: MapStyleOption
    let latitudeBucket: Int
    let longitudeBucket: Int
    let width: Int
    let height: Int
    let scale: Int
    let pitch: CGFloat

    init(option: MapStyleOption, center: CLLocationCoordinate2D, scheme: ColorScheme,
         size: CGSize, scale: CGFloat) {
        self.option = option.renderedStyle(for: scheme)
        pitch = option.explorePitch
        let valid = CLLocationCoordinate2DIsValid(center)
            && center.latitude.isFinite && center.longitude.isFinite
        let coordinate = valid ? center : CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431)
        latitudeBucket = Int(floor(coordinate.latitude * 50))
        longitudeBucket = Int(floor(coordinate.longitude * 50))
        width = size.width.isFinite ? Int(min(512, max(44, size.width))) : 220
        height = size.height.isFinite ? Int(min(512, max(44, size.height))) : 165
        self.scale = scale.isFinite ? Int(min(3, max(1, scale.rounded(.up)))) : 2
    }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: min(85.051129, max(-85.051129, (Double(latitudeBucket) + 0.5) / 50)),
                               longitude: min(180, max(-180, (Double(longitudeBucket) + 0.5) / 50)))
    }
    var size: CGSize { CGSize(width: width, height: height) }
    // v2 excludes old cropped/day-only thumbnails without deleting anyone's cache.
    var key: String { "v2_\(option.rawValue)_\(latitudeBucket)_\(longitudeBucket)_\(width)x\(height)_\(scale)_p\(Int(pitch))" }
}

/// Small, cancellable FIFO. At most two snapshots (including disk work) run at once. Identical
/// requests share work; cancelling one subscriber cannot cancel another subscriber's preview.
@MainActor
final class MapStylePreviewPipeline {
    typealias Loader = @MainActor (MapStylePreviewRequest) async -> UIImage?
    private final class Job {
        let id = UUID()
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>] = [:]
        var task: Task<Void, Never>?
    }
    private let loader: Loader
    private let limit: Int
    private let cache = NSCache<NSString, UIImage>()
    private var jobs: [MapStylePreviewRequest: Job] = [:]
    private var pending: [MapStylePreviewRequest] = []
    private var running: Set<MapStylePreviewRequest> = []

    /// Useful for verifying that every completion/cancellation releases its subscriber.
    var subscriberCount: Int { jobs.values.reduce(0) { $0 + $1.waiters.count } }

    func cachedImage(for request: MapStylePreviewRequest) -> UIImage? {
        cache.object(forKey: request.key as NSString)
    }

    init(limit: Int, loader: @escaping Loader) {
        self.limit = max(1, limit)
        self.loader = loader
        cache.countLimit = 36
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    func image(for request: MapStylePreviewRequest) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: request.key as NSString) { return image }
        let subscriber = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                let job: Job
                if let existing = jobs[request] { job = existing }
                else {
                    job = Job()
                    jobs[request] = job
                    pending.append(request)
                }
                job.waiters[subscriber] = continuation
                drain()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(request, subscriber: subscriber) }
        }
    }

    private func drain() {
        while running.count < limit, !pending.isEmpty {
            let request = pending.removeFirst()
            guard let job = jobs[request] else { continue }
            running.insert(request)
            let id = job.id
            job.task = Task {
                let image = await loader(request)
                // A cancelled render can finish after a new request for the same key begins.
                guard jobs[request]?.id == id else { return }
                finish(request, image: image)
            }
        }
    }

    private func finish(_ request: MapStylePreviewRequest, image: UIImage?) {
        guard let job = jobs.removeValue(forKey: request) else { return }
        running.remove(request)
        if let image {
            let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
            cache.setObject(image, forKey: request.key as NSString, cost: cost)
        }
        job.waiters.values.forEach { $0.resume(returning: image) }
        drain()
    }

    private func cancel(_ request: MapStylePreviewRequest, subscriber: UUID) {
        guard let job = jobs[request], let continuation = job.waiters.removeValue(forKey: subscriber)
        else { return }
        continuation.resume(returning: nil)
        guard job.waiters.isEmpty else { return }
        jobs[request] = nil
        pending.removeAll { $0 == request }
        running.remove(request)
        job.task?.cancel()
        drain()
    }
}

@MainActor
enum MapStylePreviews {
    private static let pipeline = MapStylePreviewPipeline(limit: 2, loader: load)

    private static func load(_ request: MapStylePreviewRequest) async -> UIImage? {
        #if DEBUG
        // Offline-preview UI fixture, without changing the simulator's network or map itself.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-map-preview-unavailable") { return nil }
        #endif
        if let image = await MapStylePreviewDisk.read(request) { return image }
        guard !Task.isCancelled else { return nil }
        let image = await MapStyleSnapshotRender().image(for: request)
        if let image, !Task.isCancelled { await MapStylePreviewDisk.write(image, request: request) }
        return image
    }

    static func snapshot(_ request: MapStylePreviewRequest) async -> UIImage? {
        await pipeline.image(for: request)
    }

    static func cachedImage(for request: MapStylePreviewRequest) -> UIImage? {
        pipeline.cachedImage(for: request)
    }
}

/// Disk I/O, decompression and JPEG encoding stay off the UI actor. Cache writes are atomic so
/// force-quitting during a render cannot leave a half-written thumbnail for the next launch.
private enum MapStylePreviewDisk {
    private static func url(_ request: MapStylePreviewRequest) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MapStylePreviews", isDirectory: true)
            .appendingPathComponent(request.key + ".jpg")
    }

    static func read(_ request: MapStylePreviewRequest) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let url = url(request), let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data, scale: CGFloat(request.scale)) else { return nil as UIImage? }
            return image.preparingForDisplay() ?? image
        }.value
    }

    static func write(_ image: UIImage, request: MapStylePreviewRequest) async {
        await Task.detached(priority: .utility) {
            guard let url = url(request), let data = image.jpegData(compressionQuality: 0.85) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }.value
    }
}

/// Owns every callback and resumes exactly once, including style failures, timeout and dismissal.
/// Observe BEFORE setting the style: an already-cached style may load synchronously.
@MainActor
private final class MapStyleSnapshotRender {
    private var snapshotter: Snapshotter?
    private var tokens: [AnyCancelable] = []
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<UIImage?, Never>?

    func image(for request: MapStylePreviewRequest) async -> UIImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                self.continuation = continuation
                let renderer = Snapshotter(options: MapSnapshotOptions(size: request.size,
                                                                      pixelRatio: CGFloat(request.scale)))
                snapshotter = renderer
                renderer.onStyleLoaded.observeNext { [weak self, weak renderer] _ in
                    guard let self, let renderer, self.continuation != nil else { return }
                    if let preset = request.option.standardLightPreset {
                        try? renderer.setStyleImportConfigProperty(for: "basemap", config: "lightPreset", value: preset)
                    }
                    renderer.start(overlayHandler: nil) { [weak self] result in
                        self?.finish(try? result.get())
                    }
                }.store(in: &tokens)
                renderer.onMapLoadingError.observe { [weak self] error in
                    if error.type == .style { self?.finish(nil) }
                }.store(in: &tokens)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    self?.finish(nil)
                }
                renderer.setCamera(to: CameraOptions(center: request.center, zoom: 13.8,
                                                      pitch: request.pitch))
                renderer.styleURI = request.option.styleURI
            }
        } onCancel: {
            Task { @MainActor in self.finish(nil) }
        }
    }

    private func finish(_ image: UIImage?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        tokens.removeAll()
        let renderer = snapshotter
        snapshotter = nil
        renderer?.cancel()
        continuation.resume(returning: image)
    }
}
