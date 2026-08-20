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

    /// The unlock card, in the brand's own voice (revamp 2026-08-20): a lavender-washed panel with
    /// a lock emblem in the plan-chip language (tint fill, deep glyph, purple hairline), a serif
    /// headline, the ink CTA pill, and a quiet trial line. The card glows lavender instead of
    /// casting a gray shadow — brand, not gloom — and the whole card is the tap target.
    private var unlockCard: some View {
        Button { paywall.present(for: feature) } label: {
            VStack(spacing: Theme.Space.sm) {
                // The lock emblem: a tinted circle wearing the PRO pill like a medal ribbon.
                ZStack {
                    Circle()
                        .fill(Theme.purpleTint)
                        .frame(width: 56, height: 56)
                        .overlay(Circle().stroke(Theme.purple.opacity(0.25)))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.purpleDeep)
                        .offset(y: -1)
                }
                .overlay(alignment: .bottom) {
                    Text("PRO")
                        .font(.rounded(9, weight: .heavy)).tracking(1.4)
                        .foregroundStyle(Theme.inkOnFixedLight)   // fixed dark: the badge is always light
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.proLavender))
                        .overlay(Capsule().stroke(Theme.background, lineWidth: 2))
                        .offset(y: 8)
                }
                .padding(.bottom, 6)
                .accessibilityHidden(true)

                Text(feature.lockTitle)
                    .font(.serif(22, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                Text(feature.lockBlurb)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Unlock with Pro")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold))
                    .foregroundStyle(Theme.background)       // inverts in dark mode — never invisible
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(Theme.ink))
                    .padding(.top, 8)

                Text("7-day free trial")
                    .font(.rounded(11, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.vertical, Theme.Space.lg + Theme.Space.xs)
            .padding(.horizontal, Theme.Space.xl)
            .frame(maxWidth: 258)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.background)
                    // A breath of lavender falling from the top edge — wash, never a wall.
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [Theme.purpleTint.opacity(0.75), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 110)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Theme.purple.opacity(0.22)))
            // The brand glow: a wide soft lavender ambience plus a tight contact shadow for lift.
            .shadow(color: Theme.purple.opacity(0.20), radius: 32, y: 14)
            .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
