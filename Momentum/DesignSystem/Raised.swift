import SwiftUI

// The app's raised material (glass pass 2026-08-27, promoted app-wide the same day — owner call:
// "the 3D buttons, the clean aesthetic and haptics, everywhere"). Born in the onboarding kit;
// every primitive (`OversizedButton`, `SelectionCard`, `Card`, `SegmentedCapsule`) and the inline
// panels across the app now wear it, so one file tunes the whole surface language.

// MARK: - Raised surfaces (the subtle 3D)

/// The kit's one material trick: a surface that reads as a physical, gently domed object.
/// Three cues, each barely there — a light fill gradient (lit from the top), a hairline rim that
/// catches light along the top edge and darkens along the bottom, and a two-part drop (a tight
/// contact shadow plus a soft ambient one). Ink and white variants; nothing else in the flow
/// gets to be this dimensional, so buttons and cards read as the things you press.
/// The concrete shapes the material comes in. Deliberately an enum, NOT a generic `S: Shape`:
/// a `ViewModifier` generic over the shape crashed SwiftUI on the Progress → Health segment
/// (EXC_BAD_ACCESS freeing a `StrokeShapeView` mid-layout, reproduced on a pristine build with
/// only that modifier applied, 2026-08-27). Three concrete cases sidestep it entirely.
enum RaisedShape: Equatable {
    case rounded(CGFloat)
    case capsule
    case circle

    fileprivate var any: AnyShape {
        switch self {
        case .rounded(let r): AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        case .capsule: AnyShape(Capsule())
        case .circle: AnyShape(Circle())
        }
    }
}

struct RaisedSurface: ViewModifier {
    let shape: RaisedShape
    /// `.ink` for the primary CTA, `.white` for cards and glass discs.
    enum Tone { case ink, white }
    var tone: Tone = .white
    var selected = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let fill: LinearGradient = {
            switch tone {
            case .ink:
                // ADAPTIVE (dark-mode pass 2026-08-27): a primary CTA must always be the
                // highest-contrast thing on the page. Fixed near-black read as a hole on the
                // warm charcoal — in dark it inverts to a light pill, the iOS convention this
                // app used before, with `Theme.background` as its label colour.
                return dark
                    ? LinearGradient(colors: [Color(hex: "F7F5F2"), Color(hex: "E4E1DB")],
                                     startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [Color(hex: "2C2C30"), Color(hex: "161618")],
                                     startPoint: .top, endPoint: .bottom)
            case .white:
                return dark
                    // Warm, top-lit, and a clear step above the #1E1D1B ground so a card reads
                    // as an object rather than a wash.
                    ? LinearGradient(colors: [Color(hex: "35332F"), Color(hex: "2B2926")], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [.white, Color(hex: "FAFAFB")], startPoint: .top, endPoint: .bottom)
            }
        }()
        // The rim: a light catch along the top, a whisper of shade below. In dark the bottom
        // stays FAINT — a heavy black edge there read as a crease across every card.
        let rimTop: Color = tone == .ink
            ? (dark ? .white.opacity(0.65) : .white.opacity(0.22))
            : .white.opacity(dark ? 0.09 : 0.95)
        let rimBottom: Color = tone == .ink
            ? (dark ? .black.opacity(0.10) : .black.opacity(0.5))
            : .black.opacity(dark ? 0.10 : 0.06)
        let rim = LinearGradient(colors: [rimTop, rimBottom], startPoint: .top, endPoint: .bottom)
        content
            .background {
                shape.any.fill(fill)
                // The rim: light along the top edge, shade along the bottom.
                rimView(rim, ink: false)
                // Always mounted, faded in — a conditional stroke in a background builder is
                // exactly the view SwiftUI tore down badly.
                rimView(rim, ink: true).opacity(selected ? 1 : 0)   // Theme.ink = near-white in dark
            }
            // ONE shadow on white surfaces (perf pass 2026-08-27: the card-heavy pages carried
            // two shadow layers per card — halved with no visible loss; the rim hairline already
            // gives the contact edge). Ink CTAs keep their deeper contact + ambient pair.
            .modifier(RaisedShadow(tone: tone, selected: selected, dark: dark))
    }

    @ViewBuilder private func rimView(_ style: LinearGradient, ink: Bool) -> some View {
        switch shape {
        case .rounded(let r):
            if ink { RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1.5) }
            else { RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(style, lineWidth: 1) }
        case .capsule:
            if ink { Capsule().strokeBorder(Theme.ink, lineWidth: 1.5) }
            else { Capsule().strokeBorder(style, lineWidth: 1) }
        case .circle:
            if ink { Circle().strokeBorder(Theme.ink, lineWidth: 1.5) }
            else { Circle().strokeBorder(style, lineWidth: 1) }
        }
    }
}

extension View {
    func raised(_ shape: RaisedShape, tone: RaisedSurface.Tone = .white, selected: Bool = false) -> some View {
        modifier(RaisedSurface(shape: shape, tone: tone, selected: selected))
    }
    /// Call-site sugar so `.raised(RoundedRectangle(cornerRadius: 20, style: .continuous))`,
    /// `.raised(Capsule())` and `.raised(Circle())` all read naturally.
    func raised(_ shape: RoundedRectangle, tone: RaisedSurface.Tone = .white, selected: Bool = false) -> some View {
        raised(RaisedShape.rounded(shape.cornerSize.width), tone: tone, selected: selected)
    }
    func raised(_ shape: Capsule, tone: RaisedSurface.Tone = .white, selected: Bool = false) -> some View {
        raised(RaisedShape.capsule, tone: tone, selected: selected)
    }
    func raised(_ shape: Circle, tone: RaisedSurface.Tone = .white, selected: Bool = false) -> some View {
        raised(RaisedShape.circle, tone: tone, selected: selected)
    }
}

/// Press feel for raised things: they sink a hair and lose a touch of light, like a real key.
struct RaisedPressStyle: ButtonStyle {
    var scale: CGFloat = 0.98
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: configuration.isPressed)
    }
}


private struct RaisedShadow: ViewModifier {
    let tone: RaisedSurface.Tone
    let selected: Bool
    let dark: Bool
    func body(content: Content) -> some View {
        switch tone {
        case .ink:
            content
                .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.20), radius: 16, y: 8)
        case .white:
            // Dark mode gets a REAL drop (a black shadow reads fine on charcoal) — without it the
            // cards had no separation at all and the page looked flat.
            content.shadow(color: .black.opacity(dark ? (selected ? 0.55 : 0.42) : (selected ? 0.10 : 0.07)),
                           radius: dark ? 10 : 8, y: dark ? 5 : 3)
        }
    }
}
