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

    // MARK: Multi-photo (2026-07 — WorkoutPhoto child rows, legacy photoData folds in)

    @Test func orderedPhotosRespectOrderAndHero() {
        let w = Workout()
        let a = image(100, 100), b = image(120, 120), c = image(140, 140)
        w.photos = [WorkoutPhoto(order: 2, data: c), WorkoutPhoto(order: 0, data: a), WorkoutPhoto(order: 1, data: b)]
        #expect(w.orderedPhotosData == [a, b, c])
        #expect(w.heroPhotoData == a)                        // hero is always the first by order
    }

    @Test func legacySinglePhotoStillRenders() {
        // Pre-migration workout: only the legacy field is set — display paths must keep working.
        let w = Workout()
        let legacy = image(200, 200)
        w.photoData = legacy
        #expect(w.orderedPhotosData == [legacy])
        #expect(w.heroPhotoData == legacy)
    }

    @Test func multiPhotoSetWinsOverLegacyField() {
        let w = Workout()
        let legacy = image(200, 200), new = image(300, 300)
        w.photoData = legacy
        w.photos = [WorkoutPhoto(order: 0, data: new)]
        #expect(w.orderedPhotosData == [new])                // never both
        #expect(w.heroPhotoData == new)
    }

    @Test func feedItemCarriesAllPhotosInOrder() {
        let w = Workout(); w.type = .run; w.privacy = .public
        let a = image(100, 100), b = image(120, 120)
        w.photos = [WorkoutPhoto(order: 1, data: b), WorkoutPhoto(order: 0, data: a)]
        let item = FeedAssembler.item(from: w, profile: UserProfile())
        #expect(item.photosData == [a, b])
        #expect(item.photoData == a)                         // hero convenience
    }

    @Test func photoCapIsFive() {
        // The UI cap the picker + load path both enforce (a calm card, not an album).
        #expect(Workout.photoCap == 5)
    }
}
