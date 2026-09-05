import SwiftUI

/// Liquid Glass (iOS 26) with a graceful `.regularMaterial` fallback below — the single place the
/// availability check lives, so call sites stay clean. Chrome only: floating controls/panels that
/// sit *above* content. Opaque content cards (`Card(style: .surface)`) must never use this — the
/// "chrome floats over opaque content" rule is what makes the depth read.
extension View {
    @ViewBuilder
    func momentumGlass<S: Shape>(in shape: S,
                                 iridescent: Theme.IridescentOpacity? = nil,
                                 stroke: Bool = true) -> some View {
        modifier(MomentumGlassModifier(shape: shape, iridescent: iridescent, stroke: stroke))
    }

    /// Capsule-shaped glass — the common case for chips/pills/buttons.
    func momentumGlass(iridescent: Theme.IridescentOpacity? = nil, stroke: Bool = true) -> some View {
        momentumGlass(in: Capsule(), iridescent: iridescent, stroke: stroke)
    }

    /// Make this view a reliably-tappable control when it floats over a live Mapbox map. A plain
    /// SwiftUI `Button` intermittently LOSES the gesture race to the map's UIKit tap recognizers —
    /// the tap lands, nothing happens, and it reads as a broken button. A high-priority TapGesture
    /// on a solid content shape claims the touch before the map can. Use this instead of `Button`
    /// for every glass control layered over `Map` (header pill, bell, recenter, layer picker…).
    func mapSafeTap(_ label: String, action: @escaping () -> Void) -> some View {
        modifier(MapSafeTapModifier(label: label, action: action))
    }
}

/// The tap claim plus the press feedback a `Button` would have given for free. Winning the gesture
/// race with a raw TapGesture left every map-floating control with no press state at all — touches
/// read as landing on dead glass. A zero-distance drag runs *simultaneously* (it claims nothing, so
/// the high-priority tap still beats the map) purely to know finger-down/finger-up and drive the
/// same scale the app's buttons use.
private struct MapSafeTapModifier: ViewModifier {
    let label: String
    let action: () -> Void
    // GestureState resets on cancellation as well as release. Mapbox can cancel the drag without
    // calling onEnded; a plain State then stuck down until a timer fired. No per-drag timer work.
    @GestureState private var pressed = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .modifier(PressFeedback(isPressed: pressed && isEnabled))
            .highPriorityGesture(TapGesture().onEnded { if isEnabled { action() } })
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if isEnabled { action() } }
    }
}

private struct MomentumGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let iridescent: Theme.IridescentOpacity?
    let stroke: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay { tint }
        } else {
            content
                .background { shape.fill(.regularMaterial) }
                .overlay { tint }
                .overlay { if stroke { shape.stroke(Theme.hairline) } }
        }
    }

    /// The earned iridescent wash — soft, non-interactive, clipped to the same shape.
    @ViewBuilder private var tint: some View {
        if let iridescent {
            shape
                .fill(LinearGradient(colors: Theme.iridescent, startPoint: .topLeading, endPoint: .bottomTrailing))
                .opacity(iridescent.value)
                .allowsHitTesting(false)
        }
    }
}
