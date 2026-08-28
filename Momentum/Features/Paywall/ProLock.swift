import SwiftUI

extension View {
    /// Gate this content behind Pro (PRD §10/§13.10). When `active` and the user isn't entitled, the
    /// content is frosted (blurred + a soft scrim) and a single clean "unlock" card floats centered over
    /// it, opening the paywall for `feature`. Taps don't reach the content. Entitled/inactive → untouched.
    func proLocked(_ feature: Feature, active: Bool = true) -> some View {
        modifier(ProLockModifier(feature: feature, active: active))
    }
}

private struct ProLockModifier: ViewModifier {
    let feature: Feature
    let active: Bool
    @Environment(PaywallController.self) private var paywall

    @ViewBuilder
    func body(content: Content) -> some View {
        let locked = active && !paywall.isEntitled(to: feature)
        if locked {
            content
                // Show the FULL gated content, frosted — a locked plan or trends page must read as a
                // WHOLE thing being withheld (every day, every chart), not a half-empty teaser. The
                // scrim keeps the unlock card crisp on any section, in light or dark.
                .blur(radius: 9)
                .clipped()                    // contain the blur's soft edge at the section bounds
                .overlay { Theme.background.opacity(0.55).allowsHitTesting(false) }
                .allowsHitTesting(false)
                .overlay { lockOverlay }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Locked. Unlock \(feature.displayName) with Pro")
        } else {
            // Untouched when unlocked — the zero-radius blur + clip still cost a compositing pass
            // on the largest subtrees of the app (the whole plan board, the whole trends stack).
            // The two branches ARE different structural identities, so state below resets when the
            // lock flips — acceptable: that happens once, at purchase.
            content
        }
    }

    /// Keep the card in view no matter how tall the gated section is: center it within the top band of
    /// the section (capped), so on a screen-height plan week it reads centered, and on a very tall trends
    /// page it still sits near the top — never stranded far below the fold. Consistent everywhere.
    private var lockOverlay: some View {
        GeometryReader { geo in
            unlockCard.frame(width: geo.size.width, height: min(geo.size.height, 480))
        }
    }

    /// The unlock card, minimal (owner call 2026-08-28: "simple, aesthetic, minimal, Bevel
    /// level"). One raised white card in the app's own material, an ink lock disc, a plain
    /// Inter title, one line of why, the ink CTA, a quiet fact. No lavender wash, no purple
    /// stroke, no brand glow, no serif — the previous card was a small poster; this is a control.
    private var unlockCard: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return Button { paywall.present(for: feature) } label: {
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.ink))
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)

                Text(feature.lockTitle)
                    .font(.rounded(17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(feature.lockBlurb)
                    .font(.rounded(13, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Unlock with Pro")
                    .font(.rounded(15, weight: .semibold))
                    .foregroundStyle(Theme.background)   // the raised ink is fixed-dark in both modes
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .raised(Capsule(), tone: .ink)
                    .padding(.top, 8)

                // A STORE fact, never a hardcoded promise: reads the live intro offer; placeholder
                // pricing says nothing numeric.
                Text(paywall.pricingIsLive && paywall.offering.annual.trialDays > 0
                     ? "\(paywall.offering.annual.trialDays)-day free trial" : "Cancel anytime")
                    .font(.rounded(11, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, 2)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 22)
            .frame(maxWidth: 248)
            .raised(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
