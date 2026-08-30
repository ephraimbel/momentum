import SwiftUI
import UIKit

/// A profile avatar — the athlete's chosen photo, a bundled community face, or the monogram
/// default when there's nothing else. Used everywhere an athlete appears (Today header, Profile,
/// onboarding's identity beat, Settings, the dormant feed).
///
/// **The default is monochrome on purpose.** The old fallback was a name-hashed pastel gradient,
/// built so the (dormant) community feed read as many distinct people. In a solo app it was the one
/// surface that broke the ~95% monochrome palette — random hues on the very first screen a new
/// athlete sees. Distinctness now comes from the initials and the seeded contour terrain, not from
/// color.
struct AvatarView: View {
    let photo: Data?
    let name: String
    var size: CGFloat = 36
    /// An asset-catalog image name (the seeded community's bundled synthetic face — see
    /// `CommunityAvatars`). Preferred when present: `UIImage(named:)` is cached by UIKit for the
    /// app's lifetime, so a scrolling feed never re-decodes a JPEG per row (a `photo` Data would).
    var imageName: String? = nil
    /// A curated preset look (`AvatarPreset`), rendered live — the seeded community's hash-assigned
    /// pick (`CommunityAvatars.preset(forHandle:)`). Photos always outrank it; it only replaces
    /// the plain monogram default, so a real photo can never be hidden behind a graphic.
    var preset: AvatarPreset? = nil

    /// Decoded-photo cache: `UIImage(data:)` re-parsed the JPEG on every body evaluation of every
    /// site that passes raw Data — including the Today header, which re-renders continuously while
    /// the map pans. NSCache keys on the Data object; SwiftData returns the same boxed blob until
    /// the photo actually changes, so hits are the steady state and a new photo is a clean miss.
    ///
    /// Bounded (2026-08-29): this had no limits at all, so a long browse through a social surface
    /// — every byline, every follow row, every comment — could hold one decoded bitmap per athlete
    /// photo for the life of the process. 64 faces is far more than any screen shows and the
    /// 24 MB ceiling is what an avatar cache is worth; `NSCache` also releases under real memory
    /// pressure, which an unbounded dictionary cannot.
    @MainActor private static let decoded: NSCache<NSData, UIImage> = {
        let c = NSCache<NSData, UIImage>()
        c.countLimit = 64
        c.totalCostLimit = 24 * 1_048_576
        return c
    }()

    var body: some View {
        if let imageName, let ui = UIImage(named: imageName) {
            photoAvatar(ui)
        } else if let photo, let ui = Self.decodedImage(photo) {
            photoAvatar(ui)
        } else if let preset {
            PresetAvatarView(preset: preset, name: name, size: size)
        } else {
            MonogramAvatar(name: name, size: size)
        }
    }

    @MainActor private static func decodedImage(_ data: Data) -> UIImage? {
        let key = data as NSData
        if let hit = decoded.object(forKey: key) { return hit }
        guard let ui = UIImage(data: data) else { return nil }
        // Cost is the decoded bitmap, not the JPEG — a 4 MB photo compresses to a few hundred KB
        // of data and costing it by length would let the cache hold many times its budget.
        decoded.setObject(ui, forKey: key,
                          cost: Int(ui.size.width * ui.scale * ui.size.height * ui.scale * 4))
        return ui
    }

    private func photoAvatar(_ ui: UIImage) -> some View {
        Image(uiImage: ui).resizable().scaledToFill()
            .frame(width: size, height: size).clipShape(Circle())
            .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.5))
    }

}

/// The default avatar: initials set in the display face on `Theme.surface` — nothing else. An
/// earlier pass drew seeded contour lines behind the letters; in practice they read as scribble at
/// avatar sizes (owner call, 2026-07-29), and the clean monogram is the professional look. It
/// adapts to both appearances through the tokens.
///
/// This is the single source of truth for the default: `ProfileTabIcon` renders THIS view for the
/// tab bar (via `ImageRenderer`) rather than drawing its own, so the two can never drift.
struct MonogramAvatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Theme.surface)
            if initials == "?" {
                // No name at all (possible in the dormant feed): a quiet runner glyph, not a "?"
                // that reads as an error state. Deliberately an SF Symbol, never the BrandMark —
                // the brand is not the person.
                Image(systemName: "figure.run")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
            } else {
                Text(initials)
                    .font(.display(size * 0.36, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.5))
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

}

