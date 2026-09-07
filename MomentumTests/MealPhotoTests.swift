import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import UIKit
@testable import Momentum

/// The photo the journal keeps (2026-09-07): downsampled, re-encoded, and stripped of everything
/// the camera wrote alongside the pixels.
struct MealPhotoTests {

    /// A JPEG with GPS and EXIF blocks, the way a camera roll export arrives.
    private func taggedJPEG(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // pixels, not points: the test reasons about the stored bitmap
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.brown.setFill(); ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
        let cg = try #require(image.cgImage)
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLongitude: 0.12],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test lens",
                                             kCGImagePropertyExifDateTimeOriginal: "2026:09:07 08:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Momentum tests",
                                             kCGImagePropertyTIFFModel: "Test camera"],
        ]
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test func preparedBytesCarryNoMetadataAndFitTheSizeCap() throws {
        let raw = try taggedJPEG(width: 3000, height: 2000)
        #expect(MealPhoto.carriesSensitiveMetadata(raw))
        let prepared = try #require(MealPhoto.prepare(data: raw))
        #expect(!MealPhoto.carriesSensitiveMetadata(prepared))
        #expect(MealPhoto.isSendable(prepared))
        #expect(prepared.count <= MealPhoto.maxBytes)
        let size = try #require(MealPhoto.pixelSize(of: prepared))
        #expect(max(size.width, size.height) <= MealPhoto.maxPixel)
        #expect(size.width > size.height)   // aspect kept
    }

    @Test func aSmallImageIsNotUpscaled() throws {
        let raw = try taggedJPEG(width: 400, height: 300)
        let prepared = try #require(MealPhoto.prepare(data: raw))
        let size = try #require(MealPhoto.pixelSize(of: prepared))
        #expect(size.width == 400)
        #expect(size.height == 300)
    }

    @Test func nonImageBytesAreRefused() {
        #expect(MealPhoto.prepare(data: Data("not an image".utf8)) == nil)
        #expect(!MealPhoto.isSendable(Data([0x00, 0x01, 0x02])))
    }

    @Test func aUIImageGoesThroughTheSameStrippingPath() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 2400), format: format)
        let image = renderer.image { ctx in UIColor.green.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2400, height: 2400)) }
        let prepared = try #require(MealPhoto.prepare(image: image))
        #expect(!MealPhoto.carriesSensitiveMetadata(prepared))
        let size = try #require(MealPhoto.pixelSize(of: prepared))
        #expect(size.width <= MealPhoto.maxPixel)
    }
}
