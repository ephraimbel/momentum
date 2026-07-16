import Foundation

/// Deterministic profile photos for the seeded **Momentum community** (docs/SOCIAL-LAYER.md).
///
/// Each bundled synthetic face (StyleGAN portraits that depict no real person — no right-of-publicity
/// concern for sample accounts; still clearly badged "Momentum community") is handed to **exactly one**
/// athlete, in directory order, until the gendered pools are spent. Athletes past that carry NO asset,
/// so `AvatarView` shows their initials — exactly as if they never set a profile photo. Plenty of real
/// accounts look like that, so a feed of "some faces, some monograms" reads more honest (and never
/// repeats a face) than reusing the pool across everyone. The mapping is:
///   • **unique** — no two athletes share a face (assigned once, keyed by the athlete's handle).
///   • **deterministic + stable** — same athlete → same face (or same initials) every launch, on every
///     surface (feed byline, profile header, search, comments), so identity stays coherent.
///   • **gender-consistent** — the face pool is chosen from the athlete's first name, so "Maya" never
///     lands a clearly-male portrait (a mismatch reads as fake).
///   • **cost-free at render** — resolves to an asset-catalog name; SwiftUI/UIKit cache the decoded
///     `UIImage` for the app's lifetime, so a 60-row feed never re-decodes JPEGs on the main thread.
///
/// Real network athletes (Supabase) never come through here — they carry their own `avatarData`.
enum CommunityAvatars {
    /// Bundled pool sizes — assets are named `commf-00…` (female-presenting) and `commm-00…`
    /// (male-presenting) in `Assets.xcassets`. Keep in sync with the imagesets on disk. Every face is
    /// an **adult** (fetched only from the 26-35/35-50/50+ age buckets, then hand-scanned to pull any
    /// youthful outliers) — this is an all-adults app, so no child/teen portraits ship. Regenerate
    /// with `scripts/fetch_adults.sh` + a contiguous re-number if the pool ever changes.
    static let femaleCount = 164
    static let maleCount = 155

    /// The community first-name universe skews to a fixed pool (CommunityGenerator.firstNames) plus the
    /// eight featured athletes — every one classified here so the face bucket matches the name. A name
    /// we don't recognise (shouldn't happen for seeded content) falls back to a hash-parity bucket.
    private static let femaleFirstNames: Set<String> = [
        "Maya","Lin","Priya","Sofia","Amara","Nina","Yuki","Hana","Zara","Aisha","Mei","Elena","Ines",
        "Leila","Rosa","Bianca","Freya","Tara","Ada","Carmen","Nadia","Greta","Lucia","Mira","Esme","Jade"]
    private static let maleFirstNames: Set<String> = [
        "Theo","Marcus","Devon","Jamal","Owen","Diego","Liam","Noah","Caleb","Andre","Ravi","Kofi","Tomas",
        "Sven","Kai","Omar","Hugo","Mateo","Joon","Felix","Pablo","Sami","Dario","Cole"]

    /// The avatar asset for a community athlete, or `nil` once the gendered pool is spent (→ the
    /// athlete shows their initials chip, like an account with no photo). Keyed by the unique handle,
    /// so every face is used exactly once.
    static func assetName(forHandle handle: String) -> String? { assignment[handle] }

    /// One-time unique assignment over the deterministic community directory: each athlete claims the
    /// next unused face of their gender; when a pool is spent, later athletes get no asset. Built once
    /// (lazy) — `CommunityDirectory.all()` is cached and doesn't resolve avatars while it builds, so
    /// there's no initialization cycle.
    private static let assignment: [String: String] = {
        var map: [String: String] = [:]
        var f = 0, m = 0
        for athlete in CommunityDirectory.all() where athlete.isSample {
            if isFemale(athlete.name) {
                if f < femaleCount { map[athlete.handle] = String(format: "commf-%02d", f); f += 1 }
            } else {
                if m < maleCount { map[athlete.handle] = String(format: "commm-%02d", m); m += 1 }
            }
        }
        return map
    }()

    /// Gender bucket from the first name; an unrecognised name falls back to a deterministic hash
    /// parity so it's still stable across launches.
    private static func isFemale(_ name: String) -> Bool {
        let first = String(name.split(separator: " ").first ?? "")
        if femaleFirstNames.contains(first) { return true }
        if maleFirstNames.contains(first) { return false }
        return stableHash(name) & 1 == 0
    }

    /// FNV-1a over the name — a stable, well-spread seed (no `hashValue`, which is salted per process
    /// and would reshuffle every launch).
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
}
