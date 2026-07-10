import SwiftUI

extension View {
    /// Gate this content behind Pro (PRD §10/§13.10). When `active` and the user isn't entitled, the
    /// content is blurred and capped with an "Unlock with Pro" affordance that opens the paywall for
    /// `feature`; taps don't reach the content. When entitled (or inactive) it renders untouched.
    func proLocked(_ feature: Feature, active: Bool = true) -> some View {
        modifier(ProLockModifier(feature: feature, active: active))
    }
}

private struct ProLockModifier: ViewModifier {
    let feature: Feature
    let active: Bool
    @Environment(PaywallController.self) private var paywall

    func body(content: Content) -> some View {
        let locked = active && !paywall.isEntitled(to: feature)
        content
            // Cap the locked preview to a teaser window so the "Unlock" pill stays in view even when
            // the gated content is tall (several charts).
            .frame(maxHeight: locked ? 240 : nil, alignment: .top)
            .clipped()
            .blur(radius: locked ? 7 : 0)
            .allowsHitTesting(!locked)
            .overlay { if locked { unlock } }
            .accessibilityElement(children: locked ? .ignore : .contain)
            .accessibilityLabel(locked ? "Locked — unlock \(feature.displayName) with Pro" : "")
    }

    private var unlock: some View {
        Button { paywall.present(for: feature) } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .bold))
                Text("Unlock with Pro").font(.rounded(Theme.FontSize.body, weight: .bold))
            }
            // Inverted pair, not fixed white: ink flips to near-white in dark mode, so a fixed
            // white label vanished on it. Theme.background is always ink's opposite.
            .foregroundStyle(Theme.background)
            .padding(.horizontal, Theme.Space.lg).padding(.vertical, 12)
            .background {
                Capsule().fill(Theme.ink)
                Capsule().stroke(Theme.purple, lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
