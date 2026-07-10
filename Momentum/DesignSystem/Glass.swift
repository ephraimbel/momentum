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
        self.contentShape(Rectangle())
            .highPriorityGesture(TapGesture().onEnded(action))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
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

