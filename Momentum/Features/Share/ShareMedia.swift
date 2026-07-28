import SwiftUI
import AVFoundation

/// What a photo-style share card wears behind the overlay: the athlete's still, or their clip.
enum ShareMedia: Equatable {
    case image(UIImage)
    case video(URL)

    var isVideo: Bool { if case .video = self { return true }; return false }

    /// Width ÷ height of the underlying media, used to clamp the crop. Videos report their natural
    /// size with the preferred transform applied, so a portrait clip recorded in landscape-native
    /// pixels still measures as portrait.
    func aspect() async -> CGFloat {
        switch self {
        case .image(let ui):
            guard ui.size.height > 0 else { return 1 }
            return ui.size.width / ui.size.height
        case .video(let url):
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { return 1 }
            let oriented = size.applying(transform)
            let w = abs(oriented.width), h = abs(oriented.height)
            return h > 0 ? w / h : 1
        }
    }
}

/// The pan + zoom the athlete applies to their media inside the card's fixed frame — i.e. the crop.
///
/// **Stored in CANVAS units** (the 1080-wide export space), never in screen points. The composer
/// shows the card at a fraction of export size via a single `scaleEffect`, so a transform expressed
/// in canvas units renders identically in the preview and in the exported file. Storing screen
/// points instead is the classic way to ship a crop that looks right while editing and lands
/// somewhere else in the file the athlete actually posts.
struct MediaTransform: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 4
    static let identity = MediaTransform()

    /// The size the media occupies at `scale`, filling `canvas` (aspect-fill, then zoomed).
    func filledSize(aspect: CGFloat, canvas: CGSize) -> CGSize {
        guard aspect > 0, canvas.height > 0 else { return canvas }
        let canvasAspect = canvas.width / canvas.height
        let base: CGSize = aspect > canvasAspect
            ? CGSize(width: canvas.height * aspect, height: canvas.height)
            : CGSize(width: canvas.width, height: canvas.width / aspect)
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    /// Clamp so the media always COVERS the frame. Without this a drag walks the photo off the card
    /// and exports a strip of dead black down one edge, which reads as a broken export rather than a
    /// deliberate crop.
    func clamped(aspect: CGFloat, canvas: CGSize) -> MediaTransform {
        var out = self
        out.scale = min(max(scale, Self.minScale), Self.maxScale)
        let filled = out.filledSize(aspect: aspect, canvas: canvas)
        let maxX = max(0, (filled.width - canvas.width) / 2)
        let maxY = max(0, (filled.height - canvas.height) / 2)
        out.offset = CGSize(width: min(max(offset.width, -maxX), maxX),
                            height: min(max(offset.height, -maxY), maxY))
        return out
    }

    var isIdentity: Bool { self == .identity }
}

/// A muted, endlessly looping clip that fills its frame — the card's moving backdrop.
///
/// `AVPlayerLayer` rather than AVKit's `VideoPlayer`: the latter draws transport controls and a
/// tap target over the whole surface, which would both spoil the card and eat the crop gestures.
struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.load(url)
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.load(url)   // no-op when the URL is unchanged
    }

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) { uiView.stop() }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        private var looper: AVPlayerLooper?
        private var loadedURL: URL?

        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func load(_ url: URL) {
            guard loadedURL != url else { return }
            loadedURL = url
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true                 // a card is watched before it's heard
            looper = AVPlayerLooper(player: queue, templateItem: item)
            playerLayer.player = queue
            playerLayer.videoGravity = .resizeAspectFill
            queue.play()
        }

        func stop() {
            playerLayer.player?.pause()
            playerLayer.player = nil
            looper = nil
        }
    }
}
