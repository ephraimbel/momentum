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

/// A run with BOTH a route and photos leads with the route map, then pages through the photos — one
/// Strava-style carousel so the map AND the athlete's shots both live on the feed card (running-first,
/// user decision 2026-07-15). Same native paging `ScrollView` as `PhotoCarousel` so it cooperates with
/// the feed's vertical scroll; the route is slide 1, photos follow, and the dot count spans both.
struct RoutePhotoCarousel: View {
    let item: FeedItem
    var height: CGFloat = 200
    /// 0 in the media-first feed card (full-bleed, square).
    var cornerRadius: CGFloat = Theme.Radius.card
    var contentMode: ContentMode = .fill
    /// Reading view only — see `FeedRouteMap.urgent`.
    var urgentRoute = false

    @State private var page: Int? = 0

    private var slideCount: Int { 1 + item.photosData.count }   // route map + each photo

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                FeedRouteMap(item: item, height: height, urgent: urgentRoute)
                    .containerRelativeFrame(.horizontal)
                    .id(0)
                ForEach(Array(item.photosData.enumerated()), id: \.offset) { i, data in
                    CarouselPhoto(data: data, height: height, contentMode: contentMode, uniform: true)
                        .containerRelativeFrame(.horizontal)
                        .id(i + 1)
                }
            }
            .scrollTargetLayout()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(alignment: .bottom) { pageDots }
        .accessibilityLabel("Route and \(item.photosData.count) photo\(item.photosData.count == 1 ? "" : "s")")
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<slideCount, id: \.self) { i in
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
    static func thumbnail(_ data: Data, maxPixel: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
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
    }
}
