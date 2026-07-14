import Foundation

/// Deterministic profile photos for the seeded **Momentum community** (docs/SOCIAL-LAYER.md).
///
/// The seeded athletes used to render initials chips, which read as placeholder, not people — a feed
/// of monograms feels dead. These map each community athlete to one of a bundled pool of **synthetic
/// faces** (StyleGAN portraits that depict no real person — so no right-of-publicity concern for
/// sample accounts; they're still clearly badged "Momentum community"). The mapping is:
///   • **deterministic + name-stable** — the same athlete always gets the same face, every launch and
///     on every surface (feed byline, profile header, search, comments), so identity stays coherent.
///   • **gender-consistent** — the face bucket is chosen from the athlete's first name, so "Maya" never
///     lands a clearly-male portrait (a mismatch reads as fake).
///   • **cost-free at render** — resolves to an asset-catalog name; SwiftUI/UIKit cache the decoded
///     `UIImage` for the app's lifetime, so a 60-row feed never re-decodes JPEGs on the main thread.
///
/// Real network athletes (Supabase) never come through here — they carry their own `avatarData`.
enum CommunityAvatars {
    /// Bundled pool sizes — assets are named `commf-00…` (female-presenting) and `commm-00…`
    /// (male-presenting) in `Assets.xcassets`. Keep in sync with the imagesets on disk.
    static let femaleCount = 22
    static let maleCount = 22

    /// The community first-name universe skews to a fixed pool (CommunityGenerator.firstNames) plus the
    /// eight featured athletes — every one classified here so the face bucket matches the name. A name
    /// we don't recognise (shouldn't happen for seeded content) falls back to a hash-parity bucket.
    private static let femaleFirstNames: Set<String> = [
        "Maya","Lin","Priya","Sofia","Amara","Nina","Yuki","Hana","Zara","Aisha","Mei","Elena","Ines",
        "Leila","Rosa","Bianca","Freya","Tara","Ada","Carmen","Nadia","Greta","Lucia","Mira","Esme","Jade"]
    private static let maleFirstNames: Set<String> = [
        "Theo","Marcus","Devon","Jamal","Owen","Diego","Liam","Noah","Caleb","Andre","Ravi","Kofi","Tomas",
        "Sven","Kai","Omar","Hugo","Mateo","Joon","Felix","Pablo","Sami","Dario","Cole"]

    /// The asset name for a community athlete's avatar, derived from their display name.
    /// Stable across launches (pure function of the name); the bucket is gendered, the index is a hash.
    static func assetName(forDisplayName name: String) -> String {
        let first = String(name.split(separator: " ").first ?? "")
        let hash = stableHash(name)
        let female: Bool
        if femaleFirstNames.contains(first) { female = true }
        else if maleFirstNames.contains(first) { female = false }
        else { female = hash & 1 == 0 }   // unrecognised name → deterministic parity fallback
        let count = female ? femaleCount : maleCount
        let idx = Int(hash % UInt64(max(count, 1)))
        return String(format: "%@-%02d", female ? "commf" : "commm", idx)
    }

    /// FNV-1a over the name — a stable, well-spread index seed (no `hashValue`, which is salted
    /// per process and would reshuffle every launch).
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
}
