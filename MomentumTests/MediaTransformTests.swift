import Foundation
import Testing
@testable import Momentum

/// The share crop, which two very different renderers have to agree on: SwiftUI draws it for the
/// composer preview, and AVFoundation re-derives it for a video export. Both read `MediaTransform`,
/// so this is the contract that keeps "what I framed" and "what I posted" the same picture.
struct MediaTransformTests {

    private let story = CGSize(width: 1080, height: 1920)   // 0.5625
    private let square = CGSize(width: 1080, height: 1080)  // 1.0

    // MARK: Fill

    @Test func aTallerMediaFillsByWidth() {
        // 9:20 clip in a 9:16 story — matches on width, overflows top and bottom.
        let filled = MediaTransform.identity.filledSize(aspect: 0.45, canvas: story)
        #expect(filled.width == 1080)
        #expect(filled.height > story.height)
    }

    @Test func aWiderMediaFillsByHeight() {
        // A landscape photo in a story — matches on height, overflows left and right.
        let filled = MediaTransform.identity.filledSize(aspect: 16.0 / 9, canvas: story)
        #expect(filled.height == story.height)
        #expect(filled.width > story.width)
    }

    @Test func zoomMultipliesTheFill() {
        let one = MediaTransform.identity.filledSize(aspect: 1, canvas: square)
        let two = MediaTransform(scale: 2, offset: .zero).filledSize(aspect: 1, canvas: square)
        #expect(two.width == one.width * 2)
        #expect(two.height == one.height * 2)
    }

    // MARK: Clamping — the media must always COVER the frame

    /// The bug this prevents: pan a photo far enough and the export carries a black strip down one
    /// edge, which reads as a broken file rather than a deliberate crop.
    @Test func panCannotUncoverTheFrame() {
        let aspect = 16.0 / 9   // wide photo: room to pan sideways, none vertically
        let shoved = MediaTransform(scale: 1, offset: CGSize(width: 9_999, height: 9_999))
            .clamped(aspect: aspect, canvas: story)

        let filled = shoved.filledSize(aspect: aspect, canvas: story)
        #expect(shoved.offset.width == (filled.width - story.width) / 2)
        #expect(shoved.offset.height == 0, "nothing overflows vertically, so there is nowhere to pan")
    }

    @Test func anExactlyFittingMediaCannotPanAtAll() {
        let t = MediaTransform(scale: 1, offset: CGSize(width: 500, height: 500))
            .clamped(aspect: story.width / story.height, canvas: story)
        #expect(t.offset == .zero)
    }

    @Test func zoomingInEarnsPanRoom() {
        let aspect = story.width / story.height
        let flat = MediaTransform(scale: 1, offset: CGSize(width: 400, height: 400))
            .clamped(aspect: aspect, canvas: story)
        let zoomed = MediaTransform(scale: 2, offset: CGSize(width: 400, height: 400))
            .clamped(aspect: aspect, canvas: story)
        #expect(flat.offset == .zero)
        #expect(zoomed.offset.width > 0 && zoomed.offset.height > 0)
    }

    @Test func scaleIsBounded() {
        #expect(MediaTransform(scale: 0.1, offset: .zero).clamped(aspect: 1, canvas: story).scale
                == MediaTransform.minScale)
        #expect(MediaTransform(scale: 99, offset: .zero).clamped(aspect: 1, canvas: story).scale
                == MediaTransform.maxScale)
    }

    /// Clamping has to settle in one pass — the composer clamps on every gesture tick, and a
    /// transform that kept drifting would creep while the athlete held still.
    @Test func clampingIsIdempotent() {
        let once = MediaTransform(scale: 3, offset: CGSize(width: 5_000, height: -5_000))
            .clamped(aspect: 0.7, canvas: story)
        let twice = once.clamped(aspect: 0.7, canvas: story)
        #expect(once == twice)
    }

    @Test func identityIsRecognisedSoTheHintCanRetire() {
        #expect(MediaTransform.identity.isIdentity)
        #expect(!MediaTransform(scale: 1.2, offset: .zero).isIdentity)
        #expect(!MediaTransform(scale: 1, offset: CGSize(width: 1, height: 0)).isIdentity)
    }

    // MARK: Format switches

    /// Switching Story → Square re-clamps against a different canvas; a crop that was legal in one
    /// must not leave a gap in the other.
    @Test func aCropStaysCoveringWhenTheFormatChanges() {
        let aspect = 0.75
        let inStory = MediaTransform(scale: 1, offset: CGSize(width: 0, height: 600))
            .clamped(aspect: aspect, canvas: story)
        let carried = inStory.clamped(aspect: aspect, canvas: square)
        let filled = carried.filledSize(aspect: aspect, canvas: square)
        #expect(abs(carried.offset.height) <= (filled.height - square.height) / 2 + 0.001)
    }
}
