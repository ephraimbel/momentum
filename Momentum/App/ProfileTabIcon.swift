import SwiftUI
import UIKit

/// The athlete's own photo as the Profile tab's icon, Instagram-style.
///
/// **Why a pre-rendered `UIImage` rather than an `AvatarView` in the label.** A tab item's icon is
/// flattened to a template by the tab bar and tinted — a photo put through that comes out a
/// silhouette. `withRenderingMode(.alwaysOriginal)` is what preserves the pixels, and it can only be
/// set on a `UIImage`, so the circle has to be drawn here rather than composed in SwiftUI.
///
/// Rendering is cheap but not free, and Today's body re-evaluates continuously under a panning
/// Mapbox map, so call sites must cache this in `@State` keyed on the avatar data — never call it
/// from `body`.
enum ProfileTabIcon {
    /// Tab icons render at 26 pt; anything larger is downsampled by the bar and anything smaller
    /// goes soft.
    static let size: CGFloat = 26

    /// The athlete's tab icon: their photo when they have one, the monogram default when they
    /// don't — Instagram shows YOUR avatar in the bar either way, and so do we now. Only a failed
    /// render returns nil (caller falls back to the SF Symbol).
    ///
    /// The monogram is `ImageRenderer` over the very same `MonogramAvatar` view the rest of the app
    /// draws — one source of truth, so the bar can never drift from the header. `colorScheme` is
    /// baked into the render, which is why the caller keys its redraw on the scheme too.
    @MainActor
    static func make(from data: Data?, name: String, colorScheme: ColorScheme, selected: Bool) -> UIImage? {
        if let data, let photo = UIImage(data: data) {
            return circular(source: photo, selected: selected)
        }
        let renderer = ImageRenderer(content:
            MonogramAvatar(name: name, size: size)
                .environment(\.colorScheme, colorScheme))
        renderer.scale = 3
        guard let monogram = renderer.uiImage else { return nil }
        return circular(source: monogram, selected: selected)
    }

    /// A circular, aspect-filled crop with the selected ring baked in.
    private static func circular(source: UIImage, selected: Bool) -> UIImage {
        let side = size
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        let image = renderer.image { ctx in
            // Selected state is a ring drawn INSIDE the bounds, so the icon's footprint never
            // changes between states — a tab item that resizes on selection makes the whole bar
            // twitch.
            let inset: CGFloat = selected ? 2.5 : 0
            let photoRect = bounds.insetBy(dx: inset, dy: inset)
            UIBezierPath(ovalIn: photoRect).addClip()
            source.draw(in: aspectFill(source.size, into: photoRect))
            ctx.cgContext.resetClip()
            if selected {
                UIColor.label.setStroke()
                let ring = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }


    /// Fill the circle without squashing the photo — avatars are rarely square.
    private static func aspectFill(_ source: CGSize, into rect: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return rect }
        let scale = max(rect.width / source.width, rect.height / source.height)
        let scaled = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: rect.midX - scaled.width / 2,
                      y: rect.midY - scaled.height / 2,
                      width: scaled.width, height: scaled.height)
    }
}
