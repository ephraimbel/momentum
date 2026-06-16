import Testing
import Foundation
import UIKit
@testable import Momentum

/// Photo posting (docs/SOCIAL-LAYER.md): downscale + feed mapping.
@MainActor
struct WorkoutPhotoTests {

    private func image(_ w: CGFloat, _ h: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1                                  // pixels == points so dimensions are predictable
        let r = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        return r.image { ctx in UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
            .pngData()!
    }

    @Test func downscaleShrinksLargeImages() {
        let big = image(2400, 1200)
        let small = WorkoutPhotoSection.downscaled(big, maxDimension: 1080)
        let ui = UIImage(data: small)!
        #expect(max(ui.size.width, ui.size.height) <= 1080 + 1)
        #expect(small.count < big.count)            // JPEG re-encode + resize is smaller
    }

    @Test func downscaleLeavesSmallImagesWithinBounds() {
        let smallSrc = image(800, 600)
        let out = WorkoutPhotoSection.downscaled(smallSrc, maxDimension: 1080)
        let ui = UIImage(data: out)!
        #expect(max(ui.size.width, ui.size.height) <= 800 + 1)   // not upscaled
    }

    @Test func feedItemCarriesThePhoto() {
        let w = Workout(); w.type = .run; w.privacy = .public
        w.photoData = image(400, 400)
        let item = FeedAssembler.item(from: w, profile: UserProfile())
        #expect(item.photoData != nil)
    }
}
