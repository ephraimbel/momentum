import SwiftUI
import UIKit

/// A profile avatar — the athlete's chosen photo, a bundled community face, or a deterministic
/// initials chip when there's nothing else (so the feed reads as many distinct people, not identical
/// orbs). Used across the social surfaces (profiles, feed bylines, comments).
struct AvatarView: View {
    let photo: Data?
    let name: String
    var size: CGFloat = 36
    /// An asset-catalog image name (the seeded community's bundled synthetic face — see
    /// `CommunityAvatars`). Preferred when present: `UIImage(named:)` is cached by UIKit for the
    /// app's lifetime, so a scrolling feed never re-decodes a JPEG per row (a `photo` Data would).
    var imageName: String? = nil

    var body: some View {
        if let imageName, let ui = UIImage(named: imageName) {
            photoAvatar(ui)
        } else if let photo, let ui = UIImage(data: photo) {
            photoAvatar(ui)
        } else {
            Circle().fill(gradient)
                .frame(width: size, height: size)
                .overlay(
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )
        }
    }

    private func photoAvatar(_ ui: UIImage) -> some View {
        Image(uiImage: ui).resizable().scaledToFill()
            .frame(width: size, height: size).clipShape(Circle())
            .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.5))
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// A stable pastel gradient derived from the name — same person, same colors every time.
    private var gradient: LinearGradient {
        var h: UInt64 = 5381
        for byte in name.utf8 { h = h &* 33 &+ UInt64(byte) }
        let hue = Double(h % 360) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.45, brightness: 0.82),
                     Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.66)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
