import SwiftUI

/// The quiet iridescent stage behind a strength surface's body figure (owner call 2026-07-30).
///
/// Muscle tiles and full-bleed strength pages sat on dead-flat `Theme.surface` while every route
/// tile got a whole map to live on — the body read bland by comparison. This is the fix: a faint
/// diagonal drift of the five brand hues with a soft corner glow, so the figure sits in light
/// instead of on cardboard.
///
/// Two rules keep it honest:
/// - **Earned**: it only ever backs a completed workout's worked muscles — the same claim the
///   figure's glowing muscle groups already make. Never behind forms, pickers, or empty states.
/// - **Static**: no motion, ever (Reduce Motion safe by construction — there is nothing to reduce).
///
/// Tuned per scheme rather than one opacity for both: light mode reads as a pastel breath over
/// the white canvas; dark mode drops the wash so warm charcoal stays warm charcoal — at light
/// mode's opacity the hues curdle into gray-lavender mud over #2A2926.
///
/// **`variation` is opt-in and changes nothing for a caller that omits it (2026-08-29).** Passing
/// nil draws the canonical wash exactly as it always has, hue for hue and point for point; the
/// community wall's glyph tiles are the only site that asks for a seeded one. See `WashVariation`.
struct IridescentWash: View {
    /// nil → the canonical wash. A value → this post's own deal of the same design language.
    var variation: WashVariation? = nil

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        // Rotating which hue leads is the whole tonal move: the same five brand stops, dealt in a
        // different order, so one tile reads a touch warmer and its neighbour a touch cooler. No
        // hue enters that was not already in the palette and no layer gets heavier — the earned
        // rule is about WHERE iridescence appears, and this is the same place it already was.
        let stops = variation.map { Self.rotated(Theme.iridescent, by: $0.tone) } ?? Theme.iridescent
        let drift = (dark ? 0.16 : 0.22) + (variation?.driftBoost ?? 0)
        let lift = (dark ? 0.24 : 0.16) + (variation?.liftBoost ?? 0)
        ZStack {
            Theme.surface
            LinearGradient(colors: stops.map { $0.opacity(drift) },
                           startPoint: variation.map { Self.end($0.axis, -1) } ?? .topLeading,
                           endPoint: variation.map { Self.end($0.axis, 1) } ?? .bottomTrailing)
            // The corner lift — reads as light falling across the figure, and keeps the wash from
            // being one flat tint (which looks like a rendering mistake, not a design).
            RadialGradient(colors: [stops[0].opacity(lift), .clear],
                           center: variation?.light ?? .topLeading,
                           startRadius: 0, endRadius: variation?.lightReach ?? 440)
        }
    }

    /// The drift's two ends as unit points on a circle wide enough to still clear the corners.
    /// At the canonical axis (π/4) this lands on (-0.009, -0.009) → (1.009, 1.009), i.e. the
    /// topLeading → bottomTrailing diagonal the un-varied wash uses.
    private static func end(_ axis: Double, _ side: Double) -> UnitPoint {
        let reach = 0.72
        return UnitPoint(x: 0.5 + side * reach * cos(axis), y: 0.5 + side * reach * sin(axis))
    }

    private static func rotated(_ colors: [Color], by k: Int) -> [Color] {
        guard !colors.isEmpty else { return colors }
        let n = ((k % colors.count) + colors.count) % colors.count
        guard n != 0 else { return colors }
        return Array(colors[n...] + colors[..<n])
    }
}

/// One post's own deal of the glyph tile — the wash under the symbol and the symbol itself.
///
/// **Why this exists (2026-08-29).** Every mapless post of a sport drew the *identical picture*:
/// `IridescentWash()` took no parameters, so the gradient ran the same way and the light fell from
/// the same corner on all of them, under the same symbol at the same 40pt in the same place. Two
/// swims side by side were byte-identical, and a wall of them read as wallpaper or as a rendering
/// bug rather than as several people's sessions. `CommunityWallTests` and
/// [[community-numbers-ledger-2026-08-28]] both named this as the structural cap on wall variety:
/// spacing can only rearrange tiles, it cannot make two of them look different.
///
/// Everything here is derived from the post's id, so a tile looks the same on every launch, in the
/// snapshot cache, and in the pager it zooms into. `UUID.hashValue` cannot be used for that — Swift
/// seeds `Hasher` per process, so the wall would re-deal itself on every cold start.
///
/// The ranges are deliberately narrow. This is variation, not decoration: the design language has
/// to stay unmistakably one language, so nothing rotates, nothing animates, no hue arrives that
/// isn't already in `Theme.iridescent`, and neither layer's opacity leaves the band the canonical
/// wash already sits in.
struct WashVariation: Hashable, Sendable {
    /// Which brand hue leads — the one axis legible at tile size, across a whole tile's area, and
    /// therefore the one `CommunityView.mediaSignature` keys the glyph tile on. A size or offset
    /// change is a nudge; a tint change is a different picture.
    let tone: Int
    /// The drift's direction in radians (canonical π/4 = topLeading → bottomTrailing).
    let axis: Double
    /// Where the corner lift falls from, and how far it reaches.
    let lightX: Double, lightY: Double
    let lightReach: Double
    /// Small weight jitters on the two layers, so tiles don't all sit at one exposure.
    let driftBoost: Double, liftBoost: Double
    /// The symbol: a multiplier on the caller's base size, an offset in units of that size (so it
    /// scales correctly from a 40pt tile glyph to a 96pt pager one), and its ink weight.
    let glyphScale: Double
    let glyphOffsetX: Double, glyphOffsetY: Double
    let glyphInk: Double

    /// How many hues the palette deals from — `Theme.iridescent.count`, stated here so the
    /// signature and its tests can talk about the axis without importing the palette.
    static let tones = 5

    var light: UnitPoint { UnitPoint(x: lightX, y: lightY) }

    init(seed: UUID) {
        var draw = Draw(state: Self.fold(seed))
        tone = draw.index(Self.tones)
        axis = draw.between(.pi / 4 - 0.72, .pi / 4 + 0.72)
        lightX = draw.between(-0.05, 0.90)
        lightY = draw.between(-0.05, 0.50)
        lightReach = draw.between(300, 540)
        driftBoost = draw.between(-0.03, 0.03)
        liftBoost = draw.between(-0.045, 0.045)
        glyphScale = draw.between(0.84, 1.14)
        glyphOffsetX = draw.between(-0.16, 0.16)
        // Biased up: the tile's bottom edge already carries the metric and the avatar chip.
        glyphOffsetY = draw.between(-0.19, 0.11)
        glyphInk = draw.between(0.76, 0.92)
    }

    /// The tile's tone without dealing the rest — `mediaSignature` runs this once per post over a
    /// well that reaches thousands of rows, and the tone is the only field it reads.
    static func tone(for seed: UUID) -> Int {
        var draw = Draw(state: fold(seed))
        return draw.index(tones)
    }

    /// FNV-1a over the id's own sixteen bytes. Stable across launches, unlike `hashValue`.
    private static func fold(_ id: UUID) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { raw in
            for byte in raw { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        }
        return h
    }

    /// SplitMix64 — a handful of integer ops per field, so a variation costs nothing next to the
    /// tile it decorates.
    private struct Draw {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
        mutating func between(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
        mutating func index(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }
}
