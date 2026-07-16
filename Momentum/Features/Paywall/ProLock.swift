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

    func body(content: Content) -> some View {
        let locked = active && !paywall.isEntitled(to: feature)
        content
            // Show the FULL gated content, frosted — a locked plan or trends page must read as a WHOLE
            // thing being withheld (every day, every chart), not a half-empty teaser. The scrim keeps the
            // unlock card crisp on any section, in light or dark.
            .blur(radius: locked ? 9 : 0)
            .clipped()                        // contain the blur's soft edge at the section bounds
            .overlay { if locked { Theme.background.opacity(0.55).allowsHitTesting(false) } }
            .allowsHitTesting(!locked)
            .overlay { if locked { lockOverlay } }
            .accessibilityElement(children: locked ? .ignore : .contain)
            .accessibilityLabel(locked ? "Locked — unlock \(feature.displayName) with Pro" : "")
    }

    /// Keep the card in view no matter how tall the gated section is: center it within the top band of
    /// the section (capped), so on a screen-height plan week it reads centered, and on a very tall trends
    /// page it still sits near the top — never stranded far below the fold. Consistent everywhere.
    private var lockOverlay: some View {
        GeometryReader { geo in
            unlockCard.frame(width: geo.size.width, height: min(geo.size.height, 480))
        }
    }

    /// One clean, editorial card that speaks the paywall's own language — a route-purple PRO badge, a
    /// serif headline, and the app's ink action button. Monochrome with a single earned accent; the whole
    /// card is the tap target, centered in its band for consistent placement everywhere.
    private var unlockCard: some View {
        Button { paywall.present(for: feature) } label: {
            VStack(spacing: Theme.Space.sm) {
                Text("PRO")
                    .font(.rounded(10, weight: .heavy)).tracking(1.6)
                    .foregroundStyle(Color(hex: "0E0E12"))     // fixed dark: the route badge is always light
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.route))

                Text(feature.lockTitle)
                    .font(.serif(20, weight: .semibold))
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
            }
            .padding(.vertical, Theme.Space.xl)
            .padding(.horizontal, Theme.Space.xl)
            .frame(maxWidth: 250)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.hairline))
            .shadow(color: .black.opacity(0.13), radius: 24, y: 10)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
