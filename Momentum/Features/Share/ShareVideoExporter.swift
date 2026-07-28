import AVFoundation
import CoreImage
import UIKit

/// Burns a share card's overlay into the athlete's own clip and writes a story-ready file.
///
/// The still path renders a SwiftUI card straight to a `UIImage`; a clip can't work that way, so the
/// card is split: `ShareBackdrop` sits this pass out (`mediaHidden`), the overlay is rendered once to
/// a transparent PNG, and every frame is composited under it while the SAME crop the composer
/// previewed is applied. The crop math lives in `MediaTransform` precisely so these two very
/// different renderers can't drift apart.
///
/// **Core Image, not `AVVideoCompositionCoreAnimationTool`.** The CoreAnimation tool is the usual
/// recipe for this and it crashes the encoder on the Simulator, which would leave the whole video
/// path unverifiable before release — and it composites in a y-up layer space whose flip is famously
/// easy to get backwards. A per-frame CI handler runs everywhere, and `ShareVideoExportTests` reads
/// exported frames back and samples their pixels, so orientation is proven rather than assumed.
enum ShareVideoExporter {

    enum Failure: LocalizedError {
        case noVideoTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:            "That clip has no video in it."
            case .exportFailed(let why):   why
            }
        }
    }

    /// Stories cap at 60s on every platform worth posting to, and an uncapped export of a 10-minute
    /// clip is a multi-hundred-megabyte file the athlete waits minutes for and then can't upload.
    static let maxDuration: CMTime = CMTime(seconds: 60, preferredTimescale: 600)

    /// - Parameters:
    ///   - overlay: the card WITHOUT its backdrop, at canvas size, alpha preserved.
    ///   - transform: the athlete's crop, in canvas units.
    ///   - canvas: export size (1080×1920 story, 1080×1080 square).
    /// - Returns: a temporary `.mp4` ready to hand to the share sheet.
    static func export(videoURL: URL,
                       overlay: UIImage,
                       transform: MediaTransform,
                       canvas: CGSize) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        // A file that isn't a movie at all throws here rather than returning an empty list; both
        // outcomes have to surface as a readable failure, never a silent empty export.
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let assetDuration = try await asset.load(.duration)
        let duration = min(assetDuration, maxDuration)
        let range = CMTimeRange(start: .zero, duration: duration)

        // MARK: Composition — video, plus audio when the clip has any.
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.exportFailed("Couldn't prepare the video track.")
        }
        try videoTrack.insertTimeRange(range, of: sourceTrack, at: .zero)
        // Carry the source's orientation onto the composition track so the CI handler is handed
        // upright frames — without it, a clip shot in portrait arrives on its side.
        videoTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)

        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? audioTrack.insertTimeRange(range, of: audio, at: .zero)
        }

        // MARK: Per-frame composite
        //
        // Normalise the overlay to CANVAS PIXELS first. `ShareCardRenderer` renders at 3× for the
        // still path, so a 1080-wide card arrives here as a 3240-wide bitmap — and Core Image works
        // in pixels, not points. Compositing it raw put a card's stat block across the middle of the
        // frame at triple size. Any renderer scale is handled, not just 3×.
        let overlayCI: CIImage? = overlay.cgImage.map { cg in
            let image = CIImage(cgImage: cg)
            guard image.extent.width > 0 else { return image }
            let fit = canvas.width / image.extent.width
            return abs(fit - 1) < 0.0001
                ? image
                : image.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
        }
        let videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
            let frame = composite(source: request.sourceImage,
                                  overlay: overlayCI,
                                  transform: transform,
                                  canvas: canvas)
            request.finish(with: frame, context: nil)
        }
        videoComposition.renderSize = canvas

        // MARK: Export
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("momentum-share-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed("Couldn't start the export.")
        }
        session.videoComposition = videoComposition
        do {
            try await session.export(to: out, as: .mp4)
        } catch {
            throw Failure.exportFailed(error.localizedDescription)
        }
        return out
    }

    // MARK: Geometry

    /// One frame: aspect-FILL the source into `canvas`, apply the athlete's zoom and pan, crop, then
    /// lay the overlay on top.
    ///
    /// Core Image's origin is bottom-LEFT while `MediaTransform.offset` is expressed the way SwiftUI
    /// reads it (y down), so the vertical pan is negated here and only here.
    static func composite(source: CIImage,
                          overlay: CIImage?,
                          transform: MediaTransform,
                          canvas: CGSize) -> CIImage {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return source }

        let fill = max(canvas.width / extent.width, canvas.height / extent.height)
        let total = fill * transform.scale

        var image = source.transformed(by: CGAffineTransform(scaleX: total, y: total))
        // Centre the scaled frame in the canvas, then pan. `image.extent.minX/minY` normalises away
        // any origin the scale left behind.
        let tx = (canvas.width - extent.width * total) / 2 + transform.offset.width - image.extent.minX
        let ty = (canvas.height - extent.height * total) / 2 - transform.offset.height - image.extent.minY
        image = image.transformed(by: CGAffineTransform(translationX: tx, y: ty))

        let bounds = CGRect(origin: .zero, size: canvas)
        var frame = image.cropped(to: bounds)
        if let overlay {
            frame = overlay.composited(over: frame)
        }
        return frame.cropped(to: bounds)
    }
}
