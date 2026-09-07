import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// The one way a food photo becomes bytes the journal keeps (2026-09-07, docs/PLAN-AND-FUEL-UPGRADE.md
/// §3.4). Every photo is decoded and re-encoded through a fresh `CGImage`, so nothing the camera
/// wrote alongside the pixels (location, device, time) survives into the meal or the estimate
/// request; the longest side is capped so a 48-megapixel capture costs a few hundred kilobytes,
/// not a store-bloating twelve; the result is always JPEG with a known upper bound the server
/// enforces too.
enum MealPhoto {
    /// The longest side, in pixels. Enough for a plate to be read; small enough to send.
    static let maxPixel: CGFloat = 1280
    static let jpegQuality: CGFloat = 0.72
    /// A hard ceiling on what the app will keep or send. `prepare` re-encodes at a lower quality
    /// until the bytes fit, so a pathological image never crosses the wire.
    static let maxBytes = 2_500_000
    static let mimeType = "image/jpeg"

    /// Bytes the journal keeps, from a raw capture or a library export. nil when the data is not
    /// an image at all.
    static func prepare(data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake the orientation in
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image)
    }

    #if canImport(UIKit)
    /// Bytes the journal keeps, from a `UIImage` the camera handed over.
    static func prepare(image: UIImage) -> Data? {
        // Go through the image's own JPEG so the orientation is baked exactly as the athlete saw it,
        // then through the metadata-free path like every other source.
        guard let raw = image.jpegData(compressionQuality: 0.92) else { return nil }
        return prepare(data: raw)
    }
    #endif

    /// Encode a bare `CGImage` as JPEG with no properties dictionary: no EXIF, no GPS, no maker
    /// notes. Steps the quality down until the bytes fit the ceiling.
    static func encode(_ image: CGImage) -> Data? {
        var quality = jpegQuality
        for _ in 0..<4 {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if out.length <= maxBytes { return out as Data }
            quality = max(0.3, quality - 0.15)
        }
        return nil
    }

    /// The pixel size of stored bytes, for tests and for the row's aspect.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Whether stored bytes still carry anything about WHERE, WHEN or with WHAT they were taken:
    /// a GPS block, camera make/model/software, capture dates, lens or user comments. ImageIO
    /// always writes a minimal TIFF/Exif block (pixel size, orientation, colour space), which is
    /// not identifying; this looks for the fields that are. False for anything `prepare` made.
    static func carriesSensitiveMetadata(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        if props[kCGImagePropertyGPSDictionary] != nil { return true }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
                        kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright]
            where tiff[key] != nil { return true }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
                        kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake, kCGImagePropertyExifUserComment,
                        kCGImagePropertyExifSubjectLocation, kCGImagePropertyExifBodySerialNumber,
                        kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifImageUniqueID]
            where exif[key] != nil { return true }
        }
        return false
    }

    /// The request field: what the server validates before it looks.
    static func isSendable(_ data: Data) -> Bool {
        data.count <= maxBytes && data.starts(with: [0xFF, 0xD8, 0xFF])
    }
}
