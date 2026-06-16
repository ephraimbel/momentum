import SwiftUI
import UIKit

/// A profile avatar — the athlete's chosen photo, or a deterministic initials chip when they haven't
/// set one (so the feed reads as many distinct people, not identical orbs). Used across the social
/// surfaces (profiles, feed bylines, comments).
struct AvatarView: View {
    let photo: Data?
    let name: String
    var size: CGFloat = 36

    var body: some View {
        if let photo, let ui = UIImage(data: photo) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.5))
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
