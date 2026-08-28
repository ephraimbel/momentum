import SwiftUI
import CoreLocation

// Share styles (PRD §4.9/§25 "multiple swipeable style templates") — the Strava-class share
// moment, in momentum's voice. What Strava taught us: the athlete's own photo is the hero,
// stats are quiet white type floating over it, the route is a brand-colored line that could
// only be theirs, and the wordmark whispers. What stays ours: monochrome discipline, Space
// Grotesk numerals, iridescence as the single earned accent — and one style nobody else has,
// the light "Paper" editorial card.

/// The template picker's vocabulary. `classic` is the free tier; the rest ride the existing
/// `Feature.allShareTemplates` gate ("every share style").
enum ShareStyle: String, CaseIterable, Identifiable {
    // Photo — the athlete's media is the card
    case photoTrio = "Postcard"    // full-bleed photo, stat trio low, route floating high
    case photoStack = "Stack"      // full-bleed photo, stats stacked down the center
    case photoMinimal = "Corner"   // photo, one small stat block in the corner (Aura's default)
    case photoBig = "Hero"         // photo, the hero number huge, the rest tiny
    // Cards — opaque, stand on their own
    case classic = "Classic"       // the original black card — free
    case paper = "Paper"           // the light editorial card — white canvas, ink type
    case splits = "Splits"         // the mile-by-mile table
    case week = "Week"             // this week so far, the ring's numbers as type
    case ticket = "Ticket"         // date · time · place as a typewriter block
    // Stickers — transparent, lay over any story ("tap to copy")
    case sticker = "Route"         // stats + route
    case bubble = "Bubble"         // the message bubble
    case verified = "Verified"     // "4.45 miles ✓" pill
    case heart = "Heart"           // "♥ 4.45 mi" pill
    case highlighter = "Marker"    // marker-highlighted line
    case sentence = "Caption"      // the newspaper sentence
    case serifLine = "Spelled"     // "Four miles." — the number as a word
    case dateStack = "Stamp"       // FRIDAY · MAR 27 · 5:48 PM | stats
    case condensed = "Loud"        // the loud condensed block

    var id: String { rawValue }
    var requiresPro: Bool { self != .classic }

    /// The library's three shelves (2026-08-27, Aura's "Create" + "Copy" split, plus our own
    /// opaque cards). The picker groups by this; nothing else reads it.
    enum Family: String, CaseIterable { case photo = "Photo", cards = "Cards", stickers = "Stickers" }
    var family: Family {
        switch self {
        case .photoTrio, .photoStack, .photoMinimal, .photoBig: .photo
        case .classic, .paper, .splits, .week, .ticket:          .cards
        default:                                                 .stickers
        }
    }
    /// Styles that carry the athlete's photo.
    var usesPhoto: Bool { family == .photo }
    /// Transparent exports — previewed over neutral gray, exported as PNG with alpha.
    var isSticker: Bool { family == .stickers }
    /// Styles whose stat block takes a `ShareStatVoice`; the rest have one fixed typography.
    var carriesVoice: Bool {
        switch self {
        case .photoTrio, .photoStack, .photoMinimal, .paper, .sticker: true
        default: false
        }
    }
}

// MARK: - Shared stat vocabulary

/// The three numbers a card leads with, derived once per workout (label, value).
struct ShareStats {
    let rows: [(label: String, value: String)]

    init(workout: Workout, weightUnit: WeightUnit, distanceUnit: DistanceUnit) {
        let time = Formatters.duration(s: workout.durationS)
        if workout.type.isStrengthStyle, let s = workout.strength {
            let volume = weightUnit == .lb ? s.totalVolumeKg * Formatters.lbPerKg : s.totalVolumeKg
            rows = [("Volume", "\(Formatters.compact(volume)) \(weightUnit == .lb ? "lb" : "kg")"),
                    ("Sets", "\(s.totalSets)"),
                    ("Time", time)]
        } else if let gps = workout.gps, gps.distanceM > 0 {
            if workout.type.discipline == .cycling {
                let speed = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
                rows = [("Distance", Formatters.distance(meters: gps.distanceM, unit: distanceUnit)),
                        ("Speed", Formatters.speed(ms: speed, unit: distanceUnit)),
                        ("Time", time)]
            } else {
                let pace = workout.durationS / (gps.distanceM / 1000)
                rows = [("Distance", Formatters.distance(meters: gps.distanceM, unit: distanceUnit)),
                        ("Pace", Formatters.pace(secPerKm: pace, unit: distanceUnit)),
                        ("Time", time)]
            }
        } else {
            rows = [("Time", time), ("Activity", workout.type.title)]
        }
    }
}

// MARK: - Stat voice (2026-08-25: the template grid's second axis)

/// How the numbers speak on a card. Four registers × the compositions above = the template grid,
/// without a hand-built view per template. Every voice uses the same `ShareStats` rows.
enum ShareStatVoice: String, CaseIterable, Identifiable {
    // Named for what the athlete SEES, never for the typeface (owner call 2026-08-27: "I don't
    // like how you put grotesk, numeral").
    case grotesk = "Labeled"   // small label over a heavy number — the original
    case numeral = "Clean"     // big number, unit raised small, no label (4.45ᵐⁱ)
    case pills = "Pills"       // each stat in a capsule
    case strip = "Line"        // one line, dot-separated, over a hairline
    var id: String { rawValue }
}

/// The stat block every styled card draws, in the chosen voice. `size` is the card canvas (all
/// type scales off its width); `ink` is the foreground (white over media, black on Paper).
struct ShareStatBlock: View {
    let rows: [(label: String, value: String)]
    let voice: ShareStatVoice
    let size: CGSize
    var ink: Color = .white
    /// Stacked lays rows down the centre instead of across.
    var vertical: Bool = false
    /// Row scale — Stacked wants bigger numerals than the trio.
    var scale: CGFloat = 1

    var body: some View {
        switch voice {
        case .grotesk:
            layout(spacing: size.height * 0.03) { row in
                VStack(spacing: size.height * 0.004) {
                    Text(row.label.uppercased())
                        .font(.rounded(size.width * 0.028 * scale, weight: .semibold)).tracking(2)
                        .foregroundStyle(ink.opacity(0.75))
                    Text(row.value)
                        .font(.display(size.width * 0.052 * scale, weight: .bold)).monospacedDigit()
                        .foregroundStyle(ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
        case .numeral:
            layout(spacing: size.height * 0.024) { row in
                let split = Self.split(row.value)
                HStack(alignment: .firstTextBaseline, spacing: size.width * 0.004) {
                    Text(split.value)
                        .font(.display(size.width * 0.068 * scale, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(split.unit ?? row.label.lowercased())
                        .font(.rounded(size.width * 0.034 * scale, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.8))
                        .baselineOffset(size.width * 0.028 * scale)
                }
            }
        case .pills:
            layout(spacing: size.height * 0.012) { row in
                Text(row.value)
                    .font(.display(size.width * 0.040 * scale, weight: .bold)).monospacedDigit()
                    .foregroundStyle(ink == .white ? .black : .white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, size.width * 0.035).padding(.vertical, size.width * 0.016)
                    .background(Capsule().fill(ink))
            }
        case .strip:
            VStack(spacing: size.height * 0.008) {
                HStack(spacing: size.width * 0.02) {
                    ForEach(rows.indices, id: \.self) { i in
                        if i > 0 {
                            Circle().fill(ink.opacity(0.6)).frame(width: size.width * 0.008, height: size.width * 0.008)
                        }
                        Text(rows[i].value)
                            .font(.display(size.width * 0.042 * scale, weight: .bold)).monospacedDigit()
                            .foregroundStyle(ink)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                Rectangle().fill(ink.opacity(0.35)).frame(height: max(1, size.width * 0.002))
                    .padding(.horizontal, size.width * 0.04)
                HStack(spacing: size.width * 0.02) {
                    ForEach(rows.indices, id: \.self) { i in
                        Text(rows[i].label.uppercased())
                            .font(.rounded(size.width * 0.022 * scale, weight: .semibold)).tracking(2)
                            .foregroundStyle(ink.opacity(0.7))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func layout<Cell: View>(spacing: CGFloat, @ViewBuilder cell: @escaping ((label: String, value: String)) -> Cell) -> some View {
        if vertical {
            VStack(spacing: spacing) {
                ForEach(rows.indices, id: \.self) { i in cell(rows[i]) }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    cell(rows[i]).frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// "4.45 mi" → ("4.45", "mi"); "7:51 /mi" → ("7:51", "/mi"); "34:55" → ("34:55", nil).
    static func split(_ value: String) -> (value: String, unit: String?) {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].first?.isNumber == true else { return (value, nil) }
        return (parts[0], parts[1])
    }
}

/// The route as the brand line: soft white casing under an iridescent core — legible on any
/// photo, unmistakably momentum (the same treatment as the live watch map).
struct ShareRoute: View {
    let coords: [CLLocationCoordinate2D]
    let lineWidth: CGFloat
    var ink: Bool = false   // Paper wants the periwinkle route color, not white casing
    /// The casing under the iridescent core; follows the card's chosen ink (`ShareInk.routeCasing`).
    var casing: Color = .white.opacity(0.92)

    var body: some View {
        ZStack {
            if !ink {
                RouteSilhouette(coords: coords)
                    .stroke(casing,
                            style: StrokeStyle(lineWidth: lineWidth * 1.9, lineCap: .round, lineJoin: .round))
            }
            RouteSilhouette(coords: coords)
                .stroke(ink ? AnyShapeStyle(Theme.proLavender)
                            : AnyShapeStyle(LinearGradient(colors: Theme.iridescent,
                                                           startPoint: .topLeading, endPoint: .bottomTrailing)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Title block (the words over the media)

/// City-or-date small, headline large — Aura's "New York, NY / Evening Run" stack, in our faces.
struct ShareTitleBlock: View {
    let title: String
    let subtitle: String
    let size: CGSize
    let ink: Color

    var body: some View {
        VStack(spacing: size.height * 0.004) {
            Text(subtitle)
                .font(.rounded(size.width * 0.028, weight: .semibold)).tracking(1)
                .foregroundStyle(ink.opacity(0.8))
            Text(title)
                .font(.display(size.width * 0.062, weight: .bold))
                .foregroundStyle(ink)
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
        }
        .shadow(color: .black.opacity(0.35), radius: size.width * 0.008, y: 1)
        .padding(.horizontal, size.width * 0.08)
    }
}

// MARK: - Photo · Trio  (photo hero, stat trio low, route floating high)

struct PhotoTrioCard: View {
    let workout: Workout
    let stats: ShareStats
    let media: ShareMedia?
    let size: CGSize
    /// Crop the athlete set by panning and pinching the preview.
    var transform: MediaTransform = .identity
    /// Media aspect, resolved off the render path; drives the crop clamp.
    var mediaAspect: CGFloat = 1
    /// How large the athlete wants the stat block and route drawn over their own picture.
    var overlayScale: CGFloat = 1
    /// Draw the overlay ONLY, over transparency — the video exporter composites this on top of the
    /// moving frames itself, so baking a still backdrop in would hide the clip.
    var mediaHidden: Bool = false
    var voice: ShareStatVoice = .grotesk
    var edits: ShareEdits = ShareEdits()

    var body: some View {
        let ink = edits.ink.color
        ZStack {
            ShareBackdrop(media: media, transform: transform, aspect: mediaAspect,
                          size: size, hidden: mediaHidden)
            // Legibility scrims — only where the type lives: a light one under the title, the
            // usual one under the stats. Both drop out with the ink set to "ink" (pale media).
            if edits.ink != .ink {
                LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                       .init(color: .clear, location: 0.22),
                                       .init(color: .clear, location: 0.45),
                                       .init(color: .black.opacity(0.55), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }

            VStack(spacing: 0) {
                if edits.showTitle {
                    ShareTitleBlock(title: edits.resolvedTitle(for: workout),
                                    subtitle: edits.resolvedSubtitle(for: workout),
                                    size: size, ink: ink)
                        .padding(.top, size.height * 0.07)
                }
                if edits.showRoute, let coords = routeCoords {
                    ShareRoute(coords: coords, lineWidth: size.width * 0.011, casing: edits.ink.routeCasing)
                        .frame(height: size.height * 0.30)
                        .padding(.horizontal, size.width * 0.16)
                        .padding(.top, size.height * (edits.showTitle ? 0.04 : 0.12))
                        // Anchored to its own outer edge so growing the overlay pushes it INWARD.
                        // Scaling the whole composition about centre instead walks the route off
                        // the top of the card and the stats off the bottom.
                        .scaleEffect(overlayScale, anchor: .top)
                }
                Spacer(minLength: 0)
                VStack(spacing: size.height * 0.016) {
                    if edits.showWordmark {
                        Text("momentum")
                            .font(.display(size.width * 0.055, weight: .bold))
                            .foregroundStyle(ink)
                    }
                    if edits.showStats {
                        ShareStatBlock(rows: stats.rows, voice: voice, size: size, ink: ink)
                            .shadow(color: .black.opacity(0.35), radius: size.width * 0.008, y: 1)
                            .padding(.horizontal, size.width * 0.06)
                    }
                }
                .padding(.bottom, size.height * 0.10)
                .scaleEffect(overlayScale, anchor: .bottom)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var routeCoords: [CLLocationCoordinate2D]? {
        guard let gps = workout.gps else { return nil }
        let coords = gps.routeCoordinates(type: workout.type)
        return coords.count > 1 ? coords : nil
    }
}

// MARK: - Photo · Stacked  (stats down the center, small route beneath)

struct PhotoStackCard: View {
    let workout: Workout
    let stats: ShareStats
    let media: ShareMedia?
    let size: CGSize
    var transform: MediaTransform = .identity
    var mediaAspect: CGFloat = 1
    var overlayScale: CGFloat = 1
    var mediaHidden: Bool = false
    var voice: ShareStatVoice = .grotesk
    var edits: ShareEdits = ShareEdits()

    var body: some View {
        let ink = edits.ink.color
        ZStack {
            ShareBackdrop(media: media, transform: transform, aspect: mediaAspect,
                          size: size, hidden: mediaHidden)
            if edits.ink != .ink {
                Color.black.opacity(0.28)   // quiet full veil so center type always reads
            }

            VStack(spacing: size.height * 0.030) {
                Spacer(minLength: 0)
                if edits.showTitle {
                    ShareTitleBlock(title: edits.resolvedTitle(for: workout),
                                    subtitle: edits.resolvedSubtitle(for: workout),
                                    size: size, ink: ink)
                }
                if edits.showStats {
                    ShareStatBlock(rows: stats.rows, voice: voice, size: size, ink: ink, vertical: true, scale: 1.5)
                }
                if edits.showRoute, let gps = workout.gps {
                    let coords = gps.routeCoordinates(type: workout.type)
                    if coords.count > 1 {
                        ShareRoute(coords: coords, lineWidth: size.width * 0.009, casing: edits.ink.routeCasing)
                            .frame(height: size.height * 0.14)
                            .frame(width: size.width * 0.36)
                            .padding(.top, size.height * 0.015)
                    }
                }
                if edits.showWordmark {
                    Text("momentum")
                        .font(.display(size.width * 0.045, weight: .bold))
                        .foregroundStyle(ink.opacity(0.9))
                        .padding(.top, size.height * 0.01)
                }
                Spacer(minLength: 0)
            }
            .shadow(color: .black.opacity(0.3), radius: size.width * 0.008, y: 1)
            // Stacked is composed about the centre, so it scales about the centre.
            .scaleEffect(overlayScale)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Full-bleed media under the overlay — a still, a looping clip, or a quiet brand canvas when the
/// athlete hasn't chosen anything yet.
///
/// The crop is applied here and NOWHERE else, so the composer preview and the exported file cannot
/// disagree about it: the media is laid out at its aspect-filled size, scaled and offset in canvas
/// units, then clipped to the card. The preview differs from the export only by the uniform
/// `scaleEffect` the composer wraps the whole card in.
struct ShareBackdrop: View {
    let media: ShareMedia?
    var transform: MediaTransform = .identity
    var aspect: CGFloat = 1
    let size: CGSize
    /// True while rendering the overlay pass for a video export — the clip itself is composited by
    /// AVFoundation, so this pass must leave the backdrop fully transparent.
    var hidden: Bool = false

    /// Aspect-filled size before the athlete's zoom, in canvas units.
    private var fill: CGSize {
        MediaTransform.identity.filledSize(aspect: aspect, canvas: size)
    }

    var body: some View {
        if hidden {
            Color.clear
        } else if let media {
            Group {
                switch media {
                case .image(let ui):
                    Image(uiImage: ui).resizable().scaledToFill()
                case .video(let url):
                    LoopingVideoView(url: url)
                }
            }
            .frame(width: fill.width, height: fill.height)
            .scaleEffect(transform.scale)
            .offset(transform.offset)
            .frame(width: size.width, height: size.height)
            .clipped()
        } else {
            ZStack {
                Color.black
                IridescentView(intensity: 0.35, isStatic: true)
            }
        }
    }
}

// MARK: - Paper  (the momentum-only card: light editorial, ink on white)

struct PaperCard: View {
    let workout: Workout
    let stats: ShareStats
    let size: CGSize
    var voice: ShareStatVoice = .grotesk
    /// Paper is ink-on-white by definition, so only the words and the layers apply here.
    var edits: ShareEdits = ShareEdits()

    private var pad: CGFloat { size.width * 0.09 }

    var body: some View {
        ZStack {
            Color.white
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text((edits.showTitle ? edits.resolvedTitle(for: workout) : workout.type.title).uppercased())
                        .tracking(3).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    Text(edits.resolvedSubtitle(for: workout).uppercased())
                        .tracking(1.5)
                }
                .font(.rounded(size.width * 0.028, weight: .semibold))
                .foregroundStyle(.black.opacity(0.45))

                Spacer(minLength: 0)

                if edits.showRoute, let gps = workout.gps {
                    let coords = gps.routeCoordinates(type: workout.type)
                    if coords.count > 1 {
                        ShareRoute(coords: coords, lineWidth: size.width * 0.012, ink: true)
                            .frame(height: size.height * 0.30)
                            .frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                    }
                }

                if voice == .grotesk {
                    // The editorial ledger — label left, number right, hairline-ruled.
                    VStack(alignment: .leading, spacing: size.height * 0.018) {
                        ForEach(stats.rows.indices, id: \.self) { i in
                            HStack(alignment: .firstTextBaseline) {
                                Text(stats.rows[i].label.uppercased())
                                    .font(.rounded(size.width * 0.030, weight: .semibold)).tracking(2)
                                    .foregroundStyle(.black.opacity(0.4))
                                Spacer()
                                Text(stats.rows[i].value)
                                    .font(.display(size.width * 0.070, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(.black)
                                    .lineLimit(1).minimumScaleFactor(0.6)
                            }
                            if i < stats.rows.count - 1 {
                                Rectangle().fill(.black.opacity(0.08)).frame(height: 1)
                            }
                        }
                    }
                } else {
                    ShareStatBlock(rows: stats.rows, voice: voice, size: size, ink: .black, vertical: voice == .numeral, scale: 1.2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // The one earned accent on the page.
                IridescentView(intensity: 0.9, isStatic: true)
                    .frame(width: size.width * 0.30, height: size.height * 0.008)
                    .clipShape(Capsule())
                    .padding(.top, size.height * 0.035)

                Spacer(minLength: 0)
                if edits.showWordmark {
                    Text("momentum")
                        .font(.display(size.width * 0.05, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .padding(pad)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Sticker  (transparent — lays over any Instagram story)

struct StickerCard: View {
    let workout: Workout
    let stats: ShareStats
    let size: CGSize
    var voice: ShareStatVoice = .grotesk
    var edits: ShareEdits = ShareEdits()

    var body: some View {
        let ink = edits.ink.color
        VStack(spacing: size.height * 0.030) {
            Spacer(minLength: 0)
            if edits.showTitle {
                ShareTitleBlock(title: edits.resolvedTitle(for: workout),
                                subtitle: edits.resolvedSubtitle(for: workout),
                                size: size, ink: ink)
            }
            if edits.showRoute, let gps = workout.gps {
                let coords = gps.routeCoordinates(type: workout.type)
                if coords.count > 1 {
                    ShareRoute(coords: coords, lineWidth: size.width * 0.013, casing: edits.ink.routeCasing)
                        .frame(height: size.height * 0.30)
                        .padding(.horizontal, size.width * 0.14)
                }
            }
            if edits.showStats {
                ShareStatBlock(rows: stats.rows, voice: voice, size: size, ink: ink)
                    .padding(.horizontal, size.width * 0.05)
            }
            if edits.showWordmark {
                Text("momentum")
                    .font(.display(size.width * 0.045, weight: .bold))
                    .foregroundStyle(ink)
            }
            Spacer(minLength: 0)
        }
        .shadow(color: .black.opacity(0.45), radius: size.width * 0.008, y: 1)
        .frame(width: size.width, height: size.height)
    }
}
