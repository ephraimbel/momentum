import SwiftUI

/// Renders a SwiftUI share card to a `UIImage` at 3× (PRD §25).
@MainActor
enum ShareCardRenderer {
    static func render(_ content: some View, size: CGSize) -> UIImage {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage ?? UIImage()
    }
}
