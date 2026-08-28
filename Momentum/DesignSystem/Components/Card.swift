import SwiftUI

/// The one card container. Replaces the duplicated `panelBackground`/`card` helpers and the inline
/// `RoundedRectangle(...).fill(surface).stroke(hairline)` repeated across Plan/Progress/Summary.
///
/// - `.surface` — an opaque content card (surface fill + hairline + quiet `card` elevation).
/// - `.glass`   — floating chrome (Liquid Glass + deeper `float` elevation). Reserve for things that
///   sit above content, not for content itself.
///
/// `iridescent` adds the earned accent wash (e.g. a completed plan session) — leave nil otherwise.
struct Card<Content: View>: View {
    enum Style { case surface, glass }

    var style: Style = .surface
    var radius: CGFloat = Theme.Radius.card
    var iridescent: Theme.IridescentOpacity? = nil
    var padding: CGFloat = Theme.Space.lg
    var alignment: Alignment = .leading
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background { background }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch style {
        case .surface:
            // The raised material (glass pass 2026-08-27): top-lit white on light, the surface
            // tone with a hairline on dark; the earned wash, when asked for, rides on top.
            Color.clear
                .raised(shape)
                .overlay {
                    if let iridescent {
                        shape
                            .fill(LinearGradient(colors: Theme.iridescent,
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .opacity(iridescent.value)
                    }
                }
        case .glass:
            Color.clear
                .momentumGlass(in: shape, iridescent: iridescent)
                .elevation(Theme.Elevation.float)
        }
    }
}
