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
struct IridescentWash: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.surface
            LinearGradient(colors: Theme.iridescent.map { $0.opacity(scheme == .dark ? 0.16 : 0.22) },
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // The corner lift — reads as light falling across the figure, and keeps the wash from
            // being one flat tint (which looks like a rendering mistake, not a design).
            RadialGradient(colors: [Theme.iridescent[0].opacity(scheme == .dark ? 0.24 : 0.16), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 440)
        }
    }
}
