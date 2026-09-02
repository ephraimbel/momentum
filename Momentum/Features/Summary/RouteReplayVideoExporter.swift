import AVFoundation
import CoreLocation
import MapboxMaps
import UIKit

/// The only route value allowed to cross into the share-video encoder.
///
/// A local replay is clipped before this value can be created, so neither the Snapshotter nor the
/// video writer ever receives the athlete's precise start or finish. A shared post is already
/// clipped before upload and is deliberately not clipped a second time.
struct RouteReplayExportPlan: Sendable {
    static let privacyTrimM = 200.0

    let timeline: RouteReplayTimeline
    let title: String
    let type: WorkoutType
    let startedAt: Date
    let style: MapStyleOption
    let privacyLabel: String

    static func make(from payload: RouteReplayPayload,
                     trimM: Double = privacyTrimM) -> RouteReplayExportPlan? {
        let original = payload.timeline.geometry.map { [$0.lat, $0.lon] }
        let safe: [[Double]]
        if payload.routeIsPrivacyTrimmed {
            safe = original
        } else {
            guard let trimmed = RouteTrimmer.trimmed(original, trimM: trimM) else { return nil }
            safe = trimmed
        }

        let geometry = safe.compactMap { pair -> GeoPoint? in
            guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite,
                  (-90...90).contains(pair[0]), (-180...180).contains(pair[1]) else { return nil }
            return GeoPoint(lat: pair[0], lon: pair[1])
        }
        let timeline = RouteReplayTimeline(
            geometry: geometry,
            workoutDurationS: payload.timeline.workoutDurationS,
            totalDistanceM: payload.timeline.totalDistanceM)
        guard timeline.isPlayable else { return nil }
        return RouteReplayExportPlan(
            timeline: timeline,
            title: payload.title,
            type: payload.type,
            startedAt: payload.startedAt,
            style: payload.style,
            privacyLabel: payload.routeIsPrivacyTrimmed
                ? "PRIVACY-SAFE SHARED ROUTE"
                : "START + FINISH HIDDEN")
    }
}

/// Sendable point used between Mapbox's main-actor Snapshotter and the background encoder.
struct RouteReplayCanvasPoint: Sendable, Equatable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// One attributed basemap plus the route projected into that exact image.
struct RouteReplayVideoBackdrop: Sendable {
    let pngData: Data?
    let routePoints: [RouteReplayCanvasPoint]
    let width: Int
    let height: Int

    var size: CGSize { CGSize(width: width, height: height) }

    /// Offline-safe branded geometry. The video remains useful when Mapbox has no cached tiles;
    /// privacy and encoding never depend on a network response.
    static func fallback(for plan: RouteReplayExportPlan, size: CGSize) -> Self {
        let fitted = RouteReplayProjection.fitted(plan.timeline.geometry, in: size, inset: 64)
        return .init(pngData: nil, routePoints: fitted,
                     width: max(2, Int(size.width.rounded())),
                     height: max(2, Int(size.height.rounded())))
    }
}

/// Local equirectangular fit used only by the offline video canvas. Longitudes are unwrapped so a
/// route crossing ±180° does not draw a line around the planet.
enum RouteReplayProjection {
    static func fitted(_ geometry: [GeoPoint], in size: CGSize,
                       inset: CGFloat) -> [RouteReplayCanvasPoint] {
        guard let first = geometry.first, size.width > 0, size.height > 0 else { return [] }
        let meanLatitude = geometry.map(\.lat).reduce(0, +) / Double(geometry.count)
        let longitudeScale = max(0.01, cos(meanLatitude * .pi / 180))

        var previousRaw = first.lon
        var unwrapped = first.lon
        var raw: [(x: Double, y: Double)] = [(unwrapped * longitudeScale, -first.lat)]
        raw.reserveCapacity(geometry.count)
        for point in geometry.dropFirst() {
            var delta = point.lon - previousRaw
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            unwrapped += delta
            previousRaw = point.lon
            raw.append((unwrapped * longitudeScale, -point.lat))
        }

        let minX = raw.map(\.x).min() ?? 0
        let maxX = raw.map(\.x).max() ?? 0
        let minY = raw.map(\.y).min() ?? 0
        let maxY = raw.map(\.y).max() ?? 0
        let availableW = max(1, size.width - inset * 2)
        let availableH = max(1, size.height - inset * 2)
        let spanX = maxX - minX
        let spanY = maxY - minY
        let scale = min(spanX > 0 ? Double(availableW) / spanX : .greatestFiniteMagnitude,
                        spanY > 0 ? Double(availableH) / spanY : .greatestFiniteMagnitude)
        let finiteScale = scale.isFinite ? scale : 1
        let drawnW = spanX * finiteScale
        let drawnH = spanY * finiteScale
        let originX = (Double(size.width) - drawnW) / 2
        let originY = (Double(size.height) - drawnH) / 2
        return raw.map {
            RouteReplayCanvasPoint(x: originX + ($0.x - minX) * finiteScale,
                                   y: originY + ($0.y - minY) * finiteScale)
        }
    }
}

/// Produces one static, correctly attributed Mapbox canvas for the video. The animated line and
/// athlete are rendered by AVFoundation afterward, so export cost is one snapshot—not hundreds of
/// network-bound map renders.
@MainActor
enum RouteReplayBackdropSnapshotter {
    static let size = CGSize(width: 1_000, height: 1_000)

    static func snapshot(for plan: RouteReplayExportPlan,
                         timeoutS: Double = 18) async -> RouteReplayVideoBackdrop {
        let coordinates = plan.timeline.geometry.map(\.clCoordinate)
        let fallback = RouteReplayVideoBackdrop.fallback(for: plan, size: size)
        guard coordinates.count > 1 else { return fallback }

        let options = MapSnapshotOptions(size: size, pixelRatio: 1,
                                         showsLogo: true, showsAttribution: true)
        let snapshotter = Snapshotter(options: options)
        snapshotter.styleURI = plan.style.styleURI
        let bearing = plan.timeline.state(at: 0.45)?.bearing ?? 0
        snapshotter.setCamera(to: snapshotter.camera(
            for: coordinates,
            padding: UIEdgeInsets(top: 105, left: 74, bottom: 120, right: 74),
            bearing: bearing,
            pitch: 48))

        return await withCheckedContinuation { continuation in
            var tokens: [AnyCancelable] = []
            var finished = false
            var projected: [RouteReplayCanvasPoint] = []

            func finish(_ value: RouteReplayVideoBackdrop) {
                guard !finished else { return }
                finished = true
                tokens.removeAll()
                continuation.resume(returning: value)
            }

            snapshotter.onStyleLoaded.observeNext { _ in
                if let preset = plan.style.standardLightPreset {
                    try? snapshotter.style.setStyleImportConfigProperty(
                        for: "basemap", config: "lightPreset", value: preset)
                }
                snapshotter.start(overlayHandler: { overlay in
                    projected = coordinates.map {
                        let point = overlay.pointForCoordinate($0)
                        return RouteReplayCanvasPoint(x: point.x, y: point.y)
                    }
                }, completion: { result in
                    guard case .success(let image) = result,
                          let data = image.pngData(), projected.count == coordinates.count else {
                        finish(fallback)
                        return
                    }
                    finish(.init(pngData: data, routePoints: projected,
                                 width: Int(size.width), height: Int(size.height)))
                })
            }.store(in: &tokens)

            snapshotter.onMapLoadingError.observe { error in
                if error.type == .style { finish(fallback) }
            }.store(in: &tokens)

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeoutS))
                finish(fallback)
            }
        }
    }
}

/// Writes the privacy-safe replay as a polished 9:16 H.264 movie.
///
/// The route renderer is intentionally Core Graphics rather than a live SwiftUI/Mapbox screen
/// capture: it is deterministic, cancellable, works offline, contains no app chrome, and cannot
/// accidentally record the untrimmed local route or an incoming notification.
enum RouteReplayVideoExporter {
    enum Failure: LocalizedError {
        case cannotCreateWriter
        case cannotCreateFrame
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateWriter: "Momentum couldn't prepare the replay video."
            case .cannotCreateFrame: "Momentum couldn't draw a replay frame."
            case .encodingFailed(let reason): reason
            }
        }
    }

    static let storySize = CGSize(width: 1_080, height: 1_920)
    static let framesPerSecond: Int32 = 30

    /// `startWriting()` has already succeeded when the frame loop calls this. Any later state
    /// except writing is terminal; in particular, a failed writer never makes its input ready.
    static func isWriterActive(_ status: AVAssetWriter.Status) -> Bool {
        if case .writing = status { return true }
        return false
    }

    static func export(plan: RouteReplayExportPlan,
                       backdrop: RouteReplayVideoBackdrop,
                       distanceUnit: DistanceUnit,
                       canvas: CGSize = storySize,
                       routeDurationS: Double? = nil,
                       holdDurationS: Double = 1.0) async throws -> URL {
        let width = max(2, Int(canvas.width.rounded()) / 2 * 2)
        let height = max(2, Int(canvas.height.rounded()) / 2 * 2)
        let routeDuration = routeDurationS
            ?? min(12, max(8, plan.timeline.playbackDurationS * 0.6))
        let hold = max(0, holdDurationS)
        let totalDuration = routeDuration + hold
        let frameCount = max(2, Int(ceil(totalDuration * Double(framesPerSecond))))

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("momentum-route-replay-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: output)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width >= 1_000 ? 8_000_000 : 1_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
        guard writer.canAdd(input) else { throw Failure.cannotCreateWriter }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.encodingFailed(writer.error?.localizedDescription
                                         ?? "Momentum couldn't start the replay export.")
        }
        writer.startSession(atSourceTime: .zero)

        let scene = RenderScene(plan: plan, backdrop: backdrop,
                                distanceUnit: distanceUnit,
                                canvas: CGSize(width: width, height: height))
        do {
            for frame in 0..<frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    // A failed/cancelled writer never makes the input ready again. Polling only
                    // readiness therefore turned an encoder failure into an infinite export
                    // spinner. startWriting succeeded above, so anything but `.writing` here is
                    // terminal and must escape through the normal cleanup path.
                    guard isWriterActive(writer.status) else {
                        throw Failure.encodingFailed(writer.error?.localizedDescription
                                                     ?? "Momentum couldn't write the replay video.")
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard isWriterActive(writer.status) else {
                    throw Failure.encodingFailed(writer.error?.localizedDescription
                                                 ?? "Momentum couldn't write the replay video.")
                }
                guard let pool = adaptor.pixelBufferPool else { throw Failure.cannotCreateFrame }
                var maybeBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
                guard let buffer = maybeBuffer else { throw Failure.cannotCreateFrame }

                let timeS = Double(frame) / Double(framesPerSecond)
                let progress = min(1, max(0, timeS / max(routeDuration, 0.001)))
                try render(scene: scene, progress: progress, into: buffer)
                let timestamp = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
                guard adaptor.append(buffer, withPresentationTime: timestamp) else {
                    throw Failure.encodingFailed(writer.error?.localizedDescription
                                                 ?? "Momentum couldn't write the replay video.")
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw Failure.encodingFailed(writer.error?.localizedDescription
                                             ?? "Momentum couldn't finish the replay video.")
            }
            return output
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: - Frame renderer

    private struct RenderScene {
        let plan: RouteReplayExportPlan
        let image: UIImage?
        let points: [CGPoint]
        let cumulativeM: [Double]
        let geometryTotalM: Double
        let dateText: String
        let distanceUnit: DistanceUnit
        let canvas: CGSize
        let mapRect: CGRect

        init(plan: RouteReplayExportPlan, backdrop: RouteReplayVideoBackdrop,
             distanceUnit: DistanceUnit, canvas: CGSize) {
            self.plan = plan
            self.image = backdrop.pngData.flatMap(UIImage.init(data:))
            self.distanceUnit = distanceUnit
            self.canvas = canvas
            let side = canvas.width - 80
            let mapRect = CGRect(x: 40, y: 340, width: side, height: side)
            self.mapRect = mapRect
            let sx = side / max(backdrop.size.width, 1)
            let sy = side / max(backdrop.size.height, 1)
            self.points = backdrop.routePoints.map {
                CGPoint(x: mapRect.minX + CGFloat($0.x) * sx,
                        y: mapRect.minY + CGFloat($0.y) * sy)
            }
            var cumulative = Array(repeating: 0.0, count: plan.timeline.geometry.count)
            if plan.timeline.geometry.count > 1 {
                for index in 1..<plan.timeline.geometry.count {
                    cumulative[index] = cumulative[index - 1]
                        + plan.timeline.geometry[index - 1].distance(to: plan.timeline.geometry[index])
                }
            }
            self.cumulativeM = cumulative
            self.geometryTotalM = cumulative.last ?? 0
            self.dateText = plan.startedAt.formatted(
                .dateTime.month(.abbreviated).day().year())
        }
    }

    private static func render(scene: RenderScene, progress: Double,
                               into buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.cannotCreateFrame }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: bitmap) else {
            throw Failure.cannotCreateFrame
        }

        // UIKit's drawing APIs use a top-left origin. Pixel buffers arrive bottom-left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        drawBackground(in: context, size: scene.canvas)
        drawHeader(scene)
        drawMapCard(scene, context: context, progress: progress)
        drawMetrics(scene, progress: progress)
        drawPrivacy(scene)
    }

    private static func drawBackground(in context: CGContext, size: CGSize) {
        let colors = [
            UIColor(red: 0.118, green: 0.114, blue: 0.106, alpha: 1).cgColor,
            UIColor(red: 0.075, green: 0.071, blue: 0.086, alpha: 1).cgColor,
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero,
                                   end: CGPoint(x: size.width, y: size.height), options: [])

        let glowColors = [
            UIColor(red: 0.486, green: 0.388, blue: 0.941, alpha: 0.34).cgColor,
            UIColor.clear.cgColor,
        ] as CFArray
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: glowColors, locations: [0, 1])!
        context.drawRadialGradient(glow,
                                   startCenter: CGPoint(x: size.width * 0.84, y: size.height * 0.12),
                                   startRadius: 0,
                                   endCenter: CGPoint(x: size.width * 0.84, y: size.height * 0.12),
                                   endRadius: size.width * 0.75,
                                   options: [.drawsAfterEndLocation])
    }

    private static func drawHeader(_ scene: RenderScene) {
        drawText("MOMENTUM", at: CGPoint(x: 64, y: 78), size: 23,
                 color: UIColor.white.withAlphaComponent(0.68), display: false,
                 tracking: 4)
        let title = scene.plan.title.isEmpty ? scene.plan.type.title : scene.plan.title
        drawText(title, at: CGPoint(x: 62, y: 135), size: 62,
                 color: .white, display: true, maxWidth: scene.canvas.width - 124)
        drawText(scene.dateText.uppercased(), at: CGPoint(x: 64, y: 226), size: 20,
                 color: UIColor.white.withAlphaComponent(0.54), display: false,
                 tracking: 2.2)
    }

    private static func drawMapCard(_ scene: RenderScene, context: CGContext,
                                    progress: Double) {
        let card = UIBezierPath(roundedRect: scene.mapRect, cornerRadius: 42)
        context.saveGState()
        card.addClip()
        if let image = scene.image {
            image.draw(in: scene.mapRect)
        } else {
            UIColor(red: 0.16, green: 0.15, blue: 0.18, alpha: 1).setFill()
            UIRectFill(scene.mapRect)
            drawFallbackGrid(in: context, rect: scene.mapRect)
        }
        context.restoreGState()

        UIColor.white.withAlphaComponent(0.13).setStroke()
        card.lineWidth = 2
        card.stroke()

        guard scene.points.count > 1, scene.points.count == scene.cumulativeM.count else { return }
        drawPolyline(scene.points, context: context,
                     color: UIColor.white.withAlphaComponent(0.26), width: 13)
        drawPolyline(scene.points, context: context,
                     color: UIColor(red: 0.62, green: 0.55, blue: 0.96, alpha: 0.50), width: 8)

        let routeProgress = scene.plan.timeline.routeProgress(at: progress)
        let partial = partialPolyline(scene: scene, routeProgress: routeProgress)
        drawPolyline(partial, context: context, color: .white, width: 14)
        drawPolyline(partial, context: context,
                     color: UIColor(red: 0.486, green: 0.388, blue: 0.941, alpha: 1), width: 9)
        if let marker = partial.last {
            context.setShadow(offset: CGSize(width: 0, height: 5), blur: 14,
                              color: UIColor.black.withAlphaComponent(0.42).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: marker.x - 17, y: marker.y - 17,
                                        width: 34, height: 34)).fill()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor(red: 0.10, green: 0.09, blue: 0.12, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: marker.x - 10, y: marker.y - 10,
                                        width: 20, height: 20)).fill()
        }
    }

    private static func drawMetrics(_ scene: RenderScene, progress: Double) {
        let time = Formatters.duration(s: scene.plan.timeline.elapsedTime(at: progress))
        let distance = Formatters.distance(
            meters: scene.plan.timeline.distance(at: progress), unit: scene.distanceUnit)
        drawText(time, at: CGPoint(x: 64, y: 1_440), size: 58,
                 color: .white, display: true)
        drawText("TIME", at: CGPoint(x: 66, y: 1_516), size: 18,
                 color: UIColor.white.withAlphaComponent(0.48), display: false, tracking: 2)

        let distanceWidth = textWidth(distance, size: 58, display: true)
        drawText(distance, at: CGPoint(x: scene.canvas.width - 64 - distanceWidth, y: 1_440),
                 size: 58, color: .white, display: true)
        let label = "DISTANCE"
        let labelWidth = textWidth(label, size: 18, display: false, tracking: 2)
        drawText(label, at: CGPoint(x: scene.canvas.width - 66 - labelWidth, y: 1_516),
                 size: 18, color: UIColor.white.withAlphaComponent(0.48),
                 display: false, tracking: 2)

        drawText("KEEP MOVING.", at: CGPoint(x: 64, y: 1_620), size: 27,
                 color: UIColor.white.withAlphaComponent(0.74), display: true,
                 tracking: 1.4)
    }

    private static func drawPrivacy(_ scene: RenderScene) {
        let text = "LOCK  \(scene.plan.privacyLabel)"
        let width = textWidth(text, size: 17, display: false, tracking: 1.2) + 44
        let rect = CGRect(x: 64, y: 1_738, width: width, height: 54)
        UIColor.white.withAlphaComponent(0.10).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 27).fill()
        UIColor.white.withAlphaComponent(0.16).setStroke()
        let outline = UIBezierPath(roundedRect: rect, cornerRadius: 27)
        outline.lineWidth = 1
        outline.stroke()
        drawText(text, at: CGPoint(x: rect.minX + 22, y: rect.minY + 16), size: 17,
                 color: UIColor.white.withAlphaComponent(0.78), display: false,
                 tracking: 1.2)
    }

    private static func drawFallbackGrid(in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.055).cgColor)
        context.setLineWidth(1)
        let step: CGFloat = 72
        var x = rect.minX
        while x <= rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        var y = rect.minY
        while y <= rect.maxY {
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func partialPolyline(scene: RenderScene,
                                        routeProgress: Double) -> [CGPoint] {
        guard let first = scene.points.first, scene.geometryTotalM > 0 else { return [] }
        let target = min(1, max(0, routeProgress)) * scene.geometryTotalM
        if target <= 0 { return [first] }
        if target >= scene.geometryTotalM { return scene.points }

        var upper = 1
        while upper < scene.cumulativeM.count && scene.cumulativeM[upper] < target {
            upper += 1
        }
        guard upper < scene.points.count else { return scene.points }
        let lower = upper - 1
        let span = scene.cumulativeM[upper] - scene.cumulativeM[lower]
        let local = span > 0 ? (target - scene.cumulativeM[lower]) / span : 1
        let a = scene.points[lower], b = scene.points[upper]
        let interpolated = CGPoint(x: a.x + (b.x - a.x) * local,
                                   y: a.y + (b.y - a.y) * local)
        return Array(scene.points[0...lower]) + [interpolated]
    }

    private static func drawPolyline(_ points: [CGPoint], context: CGContext,
                                     color: UIColor, width: CGFloat) {
        guard points.count > 1 else { return }
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.beginPath()
        context.move(to: points[0])
        points.dropFirst().forEach { context.addLine(to: $0) }
        context.strokePath()
        context.restoreGState()
    }

    private static func font(size: CGFloat, display: Bool) -> UIFont {
        let name = display ? "SpaceGrotesk-Bold" : "Inter-SemiBold"
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .bold)
    }

    private static func attributes(size: CGFloat, color: UIColor, display: Bool,
                                   tracking: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        [.font: font(size: size, display: display), .foregroundColor: color,
         .kern: tracking]
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat,
                                 color: UIColor, display: Bool, tracking: CGFloat = 0,
                                 maxWidth: CGFloat = .greatestFiniteMagnitude) {
        let attributed = NSAttributedString(
            string: text,
            attributes: attributes(size: size, color: color,
                                   display: display, tracking: tracking))
        attributed.draw(with: CGRect(x: point.x, y: point.y, width: maxWidth, height: size * 1.5),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private static func textWidth(_ text: String, size: CGFloat, display: Bool,
                                  tracking: CGFloat = 0) -> CGFloat {
        NSAttributedString(string: text,
                           attributes: attributes(size: size, color: .white,
                                                  display: display, tracking: tracking))
            .size().width
    }
}
