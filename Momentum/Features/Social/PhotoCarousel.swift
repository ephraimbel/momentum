import SwiftUI
import UIKit
import ImageIO

/// Swipeable photo pager for a post's attached photos (Strava-style carousel). A single photo renders
/// plain — same frame, no page dots. Shared by the feed media block, the reading view, and the workout
/// photo section so photos look identical everywhere.
///
/// The pager is a native paging `ScrollView` (not a `.page` `TabView`): a `TabView`'s embedded
/// horizontal scroll-view swallows a *vertical* swipe that begins on the photo, so in the full-page
/// reading view an upward swipe on the photo failed to scroll the article and everything below it
/// (caption, Momentum read, footer) read as "cut off". A SwiftUI `ScrollView` with `.scrollTargetBehavior(.paging)`
/// cooperates with the vertical parent, so the whole post is always reachable.
struct PhotoCarousel: View {
    let photosData: [Data]
    var height: CGFloat = 200
    /// 0 in the media-first feed card (full-bleed, square).
    var cornerRadius: CGFloat = Theme.Radius.card
    /// `.fill` (default) crops each photo to the fixed `height` band — the compact feed/tile look.
    /// `.fit` honors the photo's aspect so the reading view shows the WHOLE image (here `height` is a
    /// max cap, not an exact height).
    var contentMode: ContentMode = .fill

    @State private var page: Int? = 0

    var body: some View {
        Group {
            if photosData.count > 1 {
                carousel
            } else if let first = photosData.first {
                CarouselPhoto(data: first, height: height, contentMode: contentMode, uniform: false)
                    .accessibilityLabel("Photo")
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(photosData.enumerated()), id: \.offset) { i, data in
                    CarouselPhoto(data: data, height: height, contentMode: contentMode, uniform: true)
                        .containerRelativeFrame(.horizontal)
                        .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .frame(height: height)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .overlay(alignment: .bottom) { pageDots }
        .accessibilityLabel("Photos, \(photosData.count)")
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<photosData.count, id: \.self) { i in
                Circle().fill(.white.opacity(i == (page ?? 0) ? 0.95 : 0.4))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.28)))
        .padding(.bottom, 10)
        .allowsHitTesting(false)
    }
}

// (`RoutePhotoCarousel` deleted 2026-07-30 — only the dormant card-feed used it.)

/// One photo in the carousel. Decodes **once, off-main, downsampled** into `@State` — a feed of
/// `UIImage(data:)` calls in `body` re-decoded full-resolution JPEGs on every render (and on every
/// like-toggle, since cards observe the reaction store). `.fill` crops to `height`; `.fit` shows the
/// whole image (aspect-honored, capped at `height`); `uniform` forces a fixed band so carousel pages
/// line up.
private struct CarouselPhoto: View {
    let data: Data
    let height: CGFloat
    let contentMode: ContentMode
    var uniform: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                if contentMode == .fill {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(maxWidth: .infinity).frame(height: height).clipped()
                } else if uniform {
                    // Fit inside a fixed band so multi-photo pages share a height (letterboxed on
                    // the surface for off-aspect shots).
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity).frame(height: height)
                        .background(Theme.surface)
                } else {
                    // Single photo: natural aspect, capped — the whole image, no crop, no bars.
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity).frame(maxHeight: height)
                }
            } else {
                Theme.surface.frame(height: contentMode == .fill || uniform ? height : height * 0.72)
            }
        }
        .task(id: data.count) { if image == nil { image = await ImageDownsampler.thumbnail(data, maxPixel: 1400) } }
    }
}

/// Decode an image **off the main thread, downsampled** via ImageIO — never hold a full-resolution
/// bitmap for a small on-screen frame, and never decode a JPEG/PNG on the main thread in a `body`
/// pass. Shared by feed photos and the Progress→History route thumbnails.
enum ImageDownsampler {
    /// Decoded results, kept for the session.
    ///
    /// Without this every appearance re-decoded from scratch: swiping to photo 2 and back to
    /// photo 1 paid the full ImageIO decode again, and the page showed a flat `Theme.surface`
    /// grey until it finished. That grey flash on a swipe you have already made is the single
    /// least "seamless" thing in the post viewer (owner ask 2026-08-29). `NSCache` is
    /// thread-safe and evicts itself under pressure, so this can never become a leak; the cost
    /// limit is bytes, so ~11 full-page photos live here at most.
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 24
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    /// Cheap, collision-safe enough for one session: the blob's length and its first and last
    /// 64 bytes. Hashing three megabytes of JPEG on every lookup would cost more than the decode.
    private static func key(_ data: Data, _ maxPixel: CGFloat) -> NSString {
        var h = Hasher()
        h.combine(data.count)
        h.combine(data.prefix(64))
        h.combine(data.suffix(64))
        h.combine(maxPixel)
        return String(h.finalize()) as NSString
    }

    /// Warm a photo the athlete is ABOUT to see — the neighbouring page in the media pager — so
    /// landing on it is instant instead of a decode. Fire-and-forget; a hit is free.
    static func prefetch(_ data: Data, maxPixel: CGFloat) {
        let k = key(data, maxPixel)
        guard cache.object(forKey: k) == nil else { return }
        Task.detached(priority: .utility) { _ = await thumbnail(data, maxPixel: maxPixel) }
    }

    static func thumbnail(_ data: Data, maxPixel: CGFloat) async -> UIImage? {
        let k = key(data, maxPixel)
        if let hit = cache.object(forKey: k) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                return UIImage(data: data)
            }
            return UIImage(cgImage: cg)
        }.value
        if let decoded {
            let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
            cache.setObject(decoded, forKey: k, cost: cost)
        }
        return decoded
    }
}
