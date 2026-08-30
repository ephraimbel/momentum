import SwiftUI

/// The curated avatar looks an athlete can pick instead of a photo — the grid in Profile → Edit,
/// and the horizontal strip on onboarding's identity beat. Twelve tiles in a strict system: four
/// motifs (monogram, wordmark, runner, track) × three worlds — the light canvas, the warm charcoal,
/// and the run-trace lavender (#B8C0FF, `Theme.route`'s light value) wearing white motifs. In the
/// Edit grid, one world per row, so it reads as a system rather than a pile.
///
/// An earlier set drew seeded contour "terrain" tiles and a ridge mark; both read as scribble at
/// avatar sizes and were cut (owner call, 2026-07-29). The discipline IS the aesthetic: type, the
/// brand's own wordmark, and clean geometry — nothing else.
///
/// **Fixed colors, not `Theme` tokens, on purpose.** A picked look is baked to a PNG in
/// `avatarData` exactly like a photo, and a photo does not re-develop itself when the phone flips
/// appearance. Freezing the palette keeps the baked image honest in both modes; the light and
/// charcoal variants exist so the athlete chooses which world their avatar lives in.
///
/// No iridescent tile: the accent marks things the athlete *earned* (CLAUDE.md), and a picked
/// avatar is a selection.
enum AvatarPreset: String, CaseIterable, Identifiable {
    // Declaration order IS the picker's grid order: one row per world.
    case monogramLight, wordmarkLight, runnerLight, trackLight
    case monogramDark, wordmarkDark, runnerDark, trackDark
    case monogramLavender, wordmarkLavender, runnerLavender, trackLavender

    var id: String { rawValue }

    // The fixed palette: the app's light surface / near-black ink, and the dark mode's warm
    // charcoal / off-white — the same worlds the app renders in, frozen.
    static let lightCanvas = Color(hex: "F4F5F8")
    static let darkCanvas = Color(hex: "1E1D1B")
    static let inkDark = Color(hex: "0E0E12")
    static let inkLight = Color(hex: "EDEDEA")
    /// The run-trace lavender — `Theme.route`'s light-world value, frozen (see the palette note).
    static let lavenderCanvas = Color(hex: "B8C0FF")

    private enum World { case light, dark, lavender }
    private var world: World {
        switch self {
        case .monogramLight, .wordmarkLight, .runnerLight, .trackLight: .light
        case .monogramDark, .wordmarkDark, .runnerDark, .trackDark: .dark
        case .monogramLavender, .wordmarkLavender, .runnerLavender, .trackLavender: .lavender
        }
    }
    /// Dark-rim treatment: true for every canvas that wants a light hairline instead of a dark one.
    var isDark: Bool { world == .dark }
    var canvas: Color {
        switch world {
        case .light: Self.lightCanvas
        case .dark: Self.darkCanvas
        case .lavender: Self.lavenderCanvas
        }
    }
    /// Motif color — white on both the charcoal AND the lavender worlds (the lavender tiles wear
    /// white by spec, like the live run trace's white casing).
    var ink: Color {
        switch world {
        case .light: Self.inkDark
        case .dark, .lavender: .white
        }
    }

    /// Bake a preset into an `avatarData`-sized PNG — the same zero-schema trick as a photo: every
    /// surface that shows an avatar already reads `avatarData`, so the look arrives everywhere.
    @MainActor
    static func bake(_ preset: AvatarPreset, name: String) -> Data? {
        let renderer = ImageRenderer(content: PresetAvatarView(preset: preset, name: name, size: 512))
        renderer.scale = 1
        return renderer.uiImage?.pngData()
    }
}

/// One preset, drawn live — used for the picker tiles and for the 512 px bake, so what you tap is
/// exactly what you get.
struct PresetAvatarView: View {
    let preset: AvatarPreset
    let name: String
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle().fill(preset.canvas)
            motif
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(preset.isDark ? .white.opacity(0.12) : .black.opacity(0.08),
                                 lineWidth: max(0.5, size * 0.004)))
    }

    /// Below this the wordmark asset is unreadable at any weight, so the brand letter stands in.
    /// Covers the wall's 20pt chip and the 42pt follow-list avatar; profile-scale marks are above it.
    private static let wordmarkFloor: CGFloat = 44
    /// Below this the track's inner lane smears into the outer one rather than reading as a lane.
    private static let trackLaneFloor: CGFloat = 56

    @ViewBuilder private var motif: some View {
        switch preset {
        case .monogramLight, .monogramDark, .monogramLavender:
            Text(initials)
                .font(.display(size * 0.36, weight: .bold))
                .foregroundStyle(preset.ink)
        case .wordmarkLight, .wordmarkDark, .wordmarkLavender:
            // The real mark, not a redrawing of it: the shipped wordmark assets, white on the
            // charcoal world and black on the light one. Sized to sit comfortably inside the
            // circle's usable width — a wordmark run to the edges reads cramped, not confident.
            //
            // BUT a whole word cannot survive a chip. At the wall's 20pt avatar the mark is drawn
            // 13.6pt wide and reads as a dirty dot, and this preset is one of the most repeated
            // faces on the first screen, so the mush is what the eye actually samples. Below the
            // legibility floor we fall back to the brand's LETTER, not to the athlete's initials:
            // a wordmark avatar says "this person wears the brand", and swapping in their monogram
            // would make one athlete wear two different identities across surfaces (the exact bug
            // just fixed in FollowingRow). Same mark, same ink, at a size that resolves.
            if size < Self.wordmarkFloor {
                Text(verbatim: "M")
                    .font(.display(size * 0.44, weight: .bold))
                    .foregroundStyle(preset.ink)
            } else {
                Image(preset.ink == .white ? "WordmarkWhite" : "WordmarkBlack")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.68)
            }
        case .runnerLight, .runnerDark, .runnerLavender:
            Image(systemName: "figure.run")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(preset.ink)
        case .trackLight, .trackDark, .trackLavender:
            // A stadium track — two concentric lanes, tilted so it reads athletic, not clinical.
            //
            // The second lane is what kills it small: at a 42pt follow-list avatar the lanes are
            // 1.9pt and 1.3pt of stroke separated by ~4pt, and antialiasing smears the pair into a
            // featureless oval. One lane with an honest minimum weight still reads as a track; two
            // smudged ones read as a blob, so below the floor we drop the inner lane and hold the
            // stroke at a width that can actually paint.
            ZStack {
                Capsule().stroke(preset.ink, lineWidth: max(1.25, size * 0.045))
                    .frame(width: size * 0.62, height: size * 0.40)
                if size >= Self.trackLaneFloor {
                    Capsule().stroke(preset.ink.opacity(0.45), lineWidth: size * 0.03)
                        .frame(width: size * 0.42, height: size * 0.22)
                }
            }
            .rotationEffect(.degrees(-16))
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "M" : letters.uppercased()
    }
}
