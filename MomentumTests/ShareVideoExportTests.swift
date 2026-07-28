import Foundation
import AVFoundation
import UIKit
import Testing
@testable import Momentum

/// The video share path, end to end: write a real clip, burn a real overlay into it, then read the
/// result back off disk.
///
/// Worth doing for real rather than mocking, because every failure mode here is geometric — a
/// renderSize that doesn't match the chosen format, a `preferredTransform` that leaves a rotated
/// clip off-canvas, an overlay composited upside down — and none of them show up until something
/// actually encodes frames.
struct ShareVideoExportTests {

    /// Samples the colour at a fractional point of a frame — (0,0) top-left, (1,1) bottom-right.
    /// Reading real pixels is the only way to catch a vertically flipped composite, which is the
    /// single most common bug in this kind of export and looks perfectly fine to every geometric
    /// assertion you can write about sizes.
    private func colour(in url: URL, at point: CGPoint) async throws -> (r: Int, g: Int, b: Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let cg = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image

        let w = cg.width, h = cg.height
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Nearest-neighbour: drawing a 1080-wide image into a one-pixel context with the default
        // filter averages a huge region and turns a hard red/blue seam into muddy purple.
        ctx.interpolationQuality = .none
        // Draw the whole image offset so the sampled point lands on the single-pixel context.
        // CGContext is y-up, `point` is y-down, hence the (1 - y).
        ctx.draw(cg, in: CGRect(x: -CGFloat(w) * point.x, y: -CGFloat(h) * (1 - point.y),
                                width: CGFloat(w), height: CGFloat(h)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// A clip whose top half and bottom half differ, so a vertical flip is unmissable.
    private func makeSplitClip(size: CGSize, seconds: Double = 0.5) async throws -> URL {
        try await makeClip(size: size, seconds: seconds) { ctx, w, h, bytesPerRow in
            // BGRA. Top half red, bottom half blue.
            for y in 0..<h {
                let top = y < h / 2
                for x in 0..<w {
                    let p = y * bytesPerRow + x * 4
                    ctx[p + 0] = top ? 0 : 255       // B
                    ctx[p + 1] = 0                   // G
                    ctx[p + 2] = top ? 255 : 0       // R
                    ctx[p + 3] = 255                 // A
                }
            }
        }
    }

    /// A short, real H.264 clip. `AVAssetWriter` rather than a fixture file: a checked-in binary is a
    /// checked-in binary, and this lets each test choose its own dimensions and content so
    /// portrait/landscape and orientation handling can both be exercised.
    private func makeClip(size: CGSize, seconds: Double = 1.0,
                          fill: ((UnsafeMutablePointer<UInt8>, Int, Int, Int) -> Void)? = nil) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-clip-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:
                                            kCVPixelFormatType_32BGRA])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let h = CVPixelBufferGetHeight(buffer), w = CVPixelBufferGetWidth(buffer)
                if let fill {
                    fill(base.assumingMemoryBound(to: UInt8.self), w, h, bytesPerRow)
                } else {
                    memset(base, 40, bytesPerRow * h)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// A translucent overlay standing in for the rendered card.
    @MainActor private func makeOverlay(_ size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.withAlphaComponent(0.5).setFill()
            ctx.fill(CGRect(x: 0, y: size.height * 0.8, width: size.width, height: size.height * 0.2))
        }
    }

    /// Isolates the fixture writer from the exporter — if this passes and the exports don't, the
    /// fault is in composition/encoding, not in the clip these tests are built on.
    @Test func theFixtureWriterProducesARealClip() async throws {
        let url = try await makeClip(size: CGSize(width: 640, height: 480))
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 640, height: 480))
    }

    @Test func exportsAStoryAtTheChosenCanvasSize() async throws {
        let canvas = CGSize(width: 1080, height: 1920)
        let clip = try await makeClip(size: CGSize(width: 640, height: 480))
        let overlay = await makeOverlay(canvas)

        let out = try await ShareVideoExporter.export(videoURL: clip, overlay: overlay,
                                                      transform: .identity, canvas: canvas)
        defer { try? FileManager.default.removeItem(at: out) }

        #expect(FileManager.default.fileExists(atPath: out.path), "nothing was written")
        let asset = AVURLAsset(url: out)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        #expect(natural == canvas, "the export must land at the chosen format, got \(natural)")
    }

    @Test func exportsASquareAtTheChosenCanvasSize() async throws {
        let canvas = CGSize(width: 1080, height: 1080)
        let clip = try await makeClip(size: CGSize(width: 480, height: 640))   // portrait source
        let overlay = await makeOverlay(canvas)

        let out = try await ShareVideoExporter.export(videoURL: clip, overlay: overlay,
                                                      transform: .identity, canvas: canvas)
        defer { try? FileManager.default.removeItem(at: out) }

        let asset = AVURLAsset(url: out)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == canvas)
    }

    /// A crop must not change what the file *is* — same canvas, same length, just different framing.
    @Test func aCroppedExportKeepsItsFormatAndLength() async throws {
        let canvas = CGSize(width: 1080, height: 1920)
        let clip = try await makeClip(size: CGSize(width: 640, height: 480))
        let overlay = await makeOverlay(canvas)
        let cropped = MediaTransform(scale: 2.5, offset: CGSize(width: 180, height: -240))
            .clamped(aspect: 640.0 / 480, canvas: canvas)

        let out = try await ShareVideoExporter.export(videoURL: clip, overlay: overlay,
                                                      transform: cropped, canvas: canvas)
        defer { try? FileManager.default.removeItem(at: out) }

        let asset = AVURLAsset(url: out)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == canvas)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 0.5 && duration < 1.5, "expected the source's ~1s, got \(duration)")
    }

    /// Stories cap at 60s everywhere worth posting; an uncapped export is a file the athlete waits
    /// minutes for and then can't upload.
    @Test func longClipsAreTrimmedToTheStoryCap() async throws {
        #expect(ShareVideoExporter.maxDuration.seconds == 60)
    }

    /// The one that matters: the overlay must land where the card drew it, and the athlete's frames
    /// must not arrive upside down. Both are invisible to any size assertion.
    @Test func theOverlayAndTheFootageAreBothRightWayUp() async throws {
        let canvas = CGSize(width: 1080, height: 1080)     // square: no letterbox maths in the way
        let clip = try await makeSplitClip(size: CGSize(width: 600, height: 600))
        defer { try? FileManager.default.removeItem(at: clip) }

        // Opaque green band across the BOTTOM fifth, exactly where a card's stats sit.
        let overlay = await MainActor.run {
            UIGraphicsImageRenderer(size: canvas).image { ctx in
                UIColor.green.setFill()
                ctx.fill(CGRect(x: 0, y: canvas.height * 0.8, width: canvas.width, height: canvas.height * 0.2))
            }
        }

        let out = try await ShareVideoExporter.export(videoURL: clip, overlay: overlay,
                                                      transform: .identity, canvas: canvas)
        defer { try? FileManager.default.removeItem(at: out) }

        // A whole column, so a failure reports the actual gradient instead of one bare triple.
        var column: [(CGFloat, (r: Int, g: Int, b: Int))] = []
        for y in stride(from: 0.1, through: 0.9, by: 0.1) {
            column.append((CGFloat(y), try await colour(in: out, at: CGPoint(x: 0.5, y: CGFloat(y)))))
        }
        let dump = column.map { "y=\(String(format: "%.1f", $0.0)) \($0.1)" }.joined(separator: ", ")

        let bottom = try await colour(in: out, at: CGPoint(x: 0.5, y: 0.9))
        #expect(bottom.g > 150 && bottom.r < 100,
                "the overlay band should be at the BOTTOM. column: \(dump)")

        // Above the band, the footage itself: red on top, blue below.
        let upper = try await colour(in: out, at: CGPoint(x: 0.5, y: 0.15))
        let lower = try await colour(in: out, at: CGPoint(x: 0.5, y: 0.65))
        #expect(upper.r > 150 && upper.b < 100, "top of the clip should be red. column: \(dump)")
        #expect(lower.b > 150 && lower.r < 100, "bottom of the clip should be blue. column: \(dump)")
    }

    @Test func aFileWithNoVideoTrackFailsLoudly() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-clip-\(UUID().uuidString).mp4")
        try Data("nope".utf8).write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }

        await #expect(throws: (any Error).self) {
            _ = try await ShareVideoExporter.export(videoURL: empty,
                                                    overlay: await makeOverlay(CGSize(width: 100, height: 100)),
                                                    transform: .identity,
                                                    canvas: CGSize(width: 1080, height: 1920))
        }
    }
}
