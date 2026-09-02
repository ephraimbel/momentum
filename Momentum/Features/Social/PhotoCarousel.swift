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
    /// Optional door into the full-screen viewer. The index is the exact photo the athlete tapped.
    var onOpen: ((Int) -> Void)? = nil

    @State private var page: Int? = 0

    var body: some View {
        Group {
            if photosData.count > 1 {
                carousel
            } else if let first = photosData.first {
                photo(first, index: 0, uniform: false)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(photosData.enumerated()), id: \.offset) { i, data in
                    photo(data, index: i, uniform: true)
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

    /// A photo stays a normal paging-scroll child, but becomes a full-surface button when the
    /// host has a viewer. Dim-only press feedback preserves the carousel's geometry while making
    /// touch-down immediate.
    @ViewBuilder
    private func photo(_ data: Data, index: Int, uniform: Bool) -> some View {
        if let onOpen {
            Button {
                Haptics.light()
                onOpen(index)
            } label: {
                CarouselPhoto(data: data, height: height, contentMode: contentMode, uniform: uniform)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PhotoOpenPressStyle())
            .accessibilityLabel(photosData.count == 1 ? "Open photo" : "Open photo \(index + 1) of \(photosData.count)")
            .accessibilityHint("Shows it full screen")
        } else {
            CarouselPhoto(data: data, height: height, contentMode: contentMode, uniform: uniform)
                .accessibilityLabel(photosData.count == 1 ? "Photo" : "Photo \(index + 1) of \(photosData.count)")
        }
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

/// A standalone photo viewer for the summary/history surfaces. The social and profile pagers use
/// `PagedPhoto` too, so a picture has one crop rule everywhere: the whole image over a blurred fill.
/// `TabView` is appropriate here because this viewer has no vertical post pager for it to compete
/// with; the immersive social surfaces keep their nested-scroll-safe `FullBleedMediaPager`.
struct PhotoLightbox: View {
    let photosData: [Data]
    @State private var page: Int
    @Environment(\.dismiss) private var dismiss

    init(photosData: [Data], initialIndex: Int = 0) {
        self.photosData = photosData
        let start = photosData.indices.contains(initialIndex) ? initialIndex : 0
        _page = State(initialValue: start)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.background.ignoresSafeArea()
                TabView(selection: $page) {
                    ForEach(Array(photosData.enumerated()), id: \.offset) { index, data in
                        PagedPhoto(data: data)
                            .ignoresSafeArea()
                            .tag(index)
                            .accessibilityLabel("Photo \(index + 1) of \(photosData.count)")
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 40, height: 40)
                                .momentumGlass(in: Circle())
                        }
                        .buttonStyle(PressableScaleStyle(scale: 0.94))
                        .accessibilityLabel("Close photo")

                        Spacer()

                        if photosData.count > 1 {
                            Text("\(page + 1)/\(photosData.count)")
                                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .momentumGlass()
                                .accessibilityLabel("Photo \(page + 1) of \(photosData.count)")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, geo.safeAreaInsets.top + Theme.Space.sm)
                .padding(.bottom, geo.safeAreaInsets.bottom)
            }
        }
        .background(Theme.background)
        .accessibilityIdentifier("photo-lightbox")
    }
}

/// No scale: shrinking a full-width carousel page exposes its background and reads as a jump.
private struct PhotoOpenPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
        .task(id: MediaFingerprint.value(data)) {
            image = nil
            image = await ImageDownsampler.thumbnail(data, maxPixel: 1400)
        }
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
    // NSCache synchronizes its own reads/writes; the annotation documents that guarantee for the
    // Swift concurrency checker while decode tasks intentionally access it off the main actor.
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
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
