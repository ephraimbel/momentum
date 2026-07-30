import Foundation

/// Deterministic profile photos for the seeded **Momentum community** (docs/SOCIAL-LAYER.md).
///
/// Each bundled synthetic face (StyleGAN portraits that depict no real person — no right-of-publicity
/// concern for sample accounts; still clearly badged "Momentum community") is handed to **exactly one**
/// athlete. Since 2026-07-29 the look is hash-MIXED through the directory (faces / preset looks /
/// monograms interleaved — see `assignment`), so the visible feed reads like a real crowd: photos,
/// picked looks, and untouched defaults side by side, never a face repeated. The mapping is:
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

    /// The avatar asset for a community athlete, or `nil` when their look is a preset or the plain
    /// monogram. Every face is still unique (assigned once, keyed by the athlete's handle).
    static func assetName(forHandle handle: String) -> String? { assignment.faces[handle] }

    /// The identity-look MIX (2026-07-29, "make the feed feel real"): each athlete's look is
    /// hash-bucketed in its own stream — ~42% wear a synthetic face (unique, gender-matched,
    /// pool-limited), ~36% picked one of the twelve preset looks (the exact grid real athletes
    /// pick from), and the rest never touched the picker (plain monogram). The old order-based
    /// assignment spent all ~319 faces on the FIRST athletes in directory order — exactly the
    /// ones the feed surfaces — so the visible page showed faces only and none of the app's own
    /// preset looks. Built once (lazy); `CommunityDirectory.all()` is cached and doesn't resolve
    /// avatars while it builds, so there's no initialization cycle.
    private static let assignment: (faces: [String: String], presets: [String: AvatarPreset]) = {
        var faces: [String: String] = [:]
        var presets: [String: AvatarPreset] = [:]
        var f = 0, m = 0
        for athlete in CommunityDirectory.all() where athlete.isSample {
            let roll = stableHash("mix:" + athlete.handle) % 100
            if roll < 42 {
                if isFemale(athlete.name), f < femaleCount {
                    faces[athlete.handle] = String(format: "commf-%02d", f); f += 1; continue
                }
                if !isFemale(athlete.name), m < maleCount {
                    faces[athlete.handle] = String(format: "commm-%02d", m); m += 1; continue
                }
                // Pool spent — fall through to a preset look rather than a monogram.
            }
            if roll < 78 {
                let h = stableHash("preset:" + athlete.handle)
                presets[athlete.handle] = weightedPresets[Int(h % UInt64(weightedPresets.count))]
            }
            // else: the monogram default — neither map carries the handle.
        }
        return (faces, presets)
    }()

    /// A curated preset look, or nil when the athlete wears a face or the monogram default. Same
    /// hash stream as the mix above — the seeded community's name draws are load-bearing
    /// sequential RNG (2026-07 realism pass) and must never be consumed from here. Keyed by
    /// handle, so the look is stable across launches and identical on every surface (feed byline,
    /// profile header, search, comments).
    static func preset(forHandle handle: String) -> AvatarPreset? { assignment.presets[handle] }

    /// The pick table, each case repeated by its weight. Monogram + runner read as everyday picks,
    /// track is occasional, and the wordmark is rare on purpose — a feed where thirty strangers
    /// all wear the brand's logo reads as staged, which is the one thing the seeded community
    /// must never do.
    private static let weightedPresets: [AvatarPreset] = {
        let weights: [(AvatarPreset, Int)] = [
            (.monogramLight, 3), (.monogramDark, 3), (.monogramLavender, 3),
            (.runnerLight, 3), (.runnerDark, 3), (.runnerLavender, 3),
            (.trackLight, 2), (.trackDark, 2), (.trackLavender, 2),
            (.wordmarkLight, 1), (.wordmarkDark, 1), (.wordmarkLavender, 1)]
        return weights.flatMap { Array(repeating: $0.0, count: $0.1) }
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
