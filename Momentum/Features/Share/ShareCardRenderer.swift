import SwiftUI

/// Renders a SwiftUI share card to a `UIImage` at 3× (PRD §25). `opaque: false` keeps alpha —
/// the Sticker style exports transparent PNGs that lay over any Instagram story.
@MainActor
enum ShareCardRenderer {
    static func render(_ content: some View, size: CGSize, opaque: Bool = true) -> UIImage {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 3
        renderer.isOpaque = opaque
        return renderer.uiImage ?? UIImage()
    }
}
