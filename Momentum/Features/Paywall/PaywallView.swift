import SwiftUI

/// The Pro paywall (PRD §10) — the app's ONE contextual gate, full-screen and unmistakably
/// premium: the warm-charcoal dark canvas, flat and still (owner calls 2026-08-05: the phone
/// mocks and the iridescent wash both went — "tacky"; this supersedes the 2026-07-29 bright-light
/// call), the wordmark centered up top, the full feature list in eight honest lines. **Trust
/// stays a feature:** two plans side by side with the yearly staged to win, plain renewal terms
/// before purchase, one-tap restore. Onboarding's (soft) gate uses the two-page
/// `OnboardingPaywallFlow` instead; both are assembled from the same `PaywallComponents`.
struct PaywallView: View {
    /// The locked feature that brought the user here — frames the subheadline.
    var feature: Feature = .aiCoach
    /// Hard placement: no close affordance, no swipe-away — the only ways forward are starting
    /// the trial, subscribing, or restoring. Contextual gates elsewhere stay dismissible; trust
    /// copy (plain renewal terms, one-tap restore) is identical in both modes.
    var hard: Bool = false
    /// Called INSTEAD of dismissing when the athlete becomes entitled — see PaywallCheckout.
    var onEntitled: (() -> Void)?

    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selected: PaywallProduct.Period = .annual
    @State private var revealed = false

    private var offering: PaywallOffering { paywall.offering }
    private var product: PaywallProduct { selected == .annual ? offering.annual : offering.monthly }

    var body: some View {
        GeometryReader { geo in
            // One scale drives the whole scrollable stack so the paywall reads *identically* on every
            // iPhone — full-size on a 6.9" Pro Max, gently condensed on a 4.7" SE — instead of the
            // plans getting shoved under the pinned CTA on short screens.
            // Divisor 820: a 6.1" Dynamic-Island phone (iPhone 15/16, ~759pt usable — the Island eats
            // MORE top inset than the 14's notch, so it's the tightest of the "tall" phones) condenses
            // ~7% so the plan pair clears the pinned CTA with margin; 6.7"+ stays clamped at 1.0
            // (pristine). Clamped so it never shrinks past legibility.
            let s = min(1, max(0.8, geo.size.height / 820))
            content(s, viewportHeight: geo.size.height)
        }
    }

    private func content(_ s: CGFloat, viewportHeight: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                lockup(s)
                    .padding(.top, Theme.Space.md * s)
                hero(s)
                    .padding(.top, (Theme.Space.sm + 2) * s)
                    .reveal(revealed, delay: 0.05, reduceMotion: reduceMotion)
                PaywallFeatureList(scale: s, boxed: true)
                    .padding(.top, (Theme.Space.md - 2) * s)
                    .reveal(revealed, delay: 0.15, reduceMotion: reduceMotion)
                // Any slack the viewport has lands HERE, not between the plans and the pinned
                // checkout (owner note 2026-08-05: no dead air above the button) — the minHeight
                // below stretches the stack to the viewport and this spacer soaks it up, so the
                // plan pair always sits directly on the checkout. Inert on short screens, where
                // content already exceeds the minimum.
                Spacer(minLength: (Theme.Space.md - 2) * s)
                PlanPairPicker(offering: offering, pricingIsLive: paywall.pricingIsLive,
                               selected: $selected, scale: s)
                    .reveal(revealed, delay: 0.25, reduceMotion: reduceMotion)
            }
            // Viewport minus the pinned checkout block (trust line + CTA + fine print + paddings,
            // ~150pt) — tuned by screenshot on a 6.1". A few points under is fine (a sliver of
            // gap); over would reintroduce a needless scroll.
            .frame(minHeight: viewportHeight - 150 * s)
            .padding(.horizontal, max(Theme.Space.lg, Theme.Space.xl * s))
            .padding(.bottom, Theme.Space.xs)
        }
        .scrollIndicators(.hidden)
        // Only the checkout is pinned — `safeAreaInset` insets the scroll content above it, so the
        // showcase and plans are never covered.
        .safeAreaInset(edge: .bottom) {
            PaywallCheckout(product: product, hard: hard, onEntitled: onEntitled)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.lg)
                // A soft scrim fades the canvas up under the CTA so that on a short screen — where
                // the content can still scroll a hair behind the (chromeless) button — anything
                // passing under it dissolves cleanly instead of peeking through. Invisible on tall
                // phones (nothing scrolls there); ignores the home-indicator inset so the fade
                // reaches the very bottom.
                .background {
                    LinearGradient(colors: [.clear, Theme.background.opacity(0.9), Theme.background],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                .reveal(revealed, delay: 0.32, reduceMotion: reduceMotion)
        }
        .background { PaywallBackground() }
        .overlay(alignment: .topTrailing) { if !hard { closeButton } }
        // The paywall is the warm-charcoal DARK moment regardless of the athlete's appearance
        // setting (owner call 2026-08-05, superseding the 2026-07-29 bright-light call). Use
        // `.environment(\.colorScheme)`, NOT `.preferredColorScheme`: the latter is a PREFERENCE
        // that flows UP to the hosting window, so on dismiss it left the presenter (e.g. the
        // coach chat) stuck in the forced scheme. Setting the environment styles only the
        // paywall's own subtree — no leak to whoever presented it.
        .environment(\.colorScheme, .dark)
        .onAppear {
            services.analytics.log(.paywallView(placement: feature.placement))
            SKANConversion.record(.paywallSeen)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { revealed = true }
        }
    }

    // MARK: Brand lockup — the wordmark, centered

    private func lockup(_ s: CGFloat) -> some View {
        VStack(spacing: Theme.Space.sm * s) {
            // The glass runner, sitting in the background's iridescent bloom — the one physical
            // object on the page (owner ask 2026-08-05: a high-end centerpiece, not just type).
            BrandMark(size: 58 * s)
                .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            // Always the white wordmark — this surface is deliberately dark (charcoal canvas).
            Image("WordmarkWhite")
                .resizable().interpolation(.high).scaledToFit().frame(height: 21 * s)
                .padding(.top, 2)
            Text("PRO").font(.rounded(11, weight: .black)).tracking(2.2).foregroundStyle(Theme.inkOnFixedLight)
                .padding(.horizontal, 10).padding(.vertical, 3.5)
                .background(Capsule().fill(Theme.proLavender))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Momentum Pro")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Hero

    private func hero(_ s: CGFloat) -> some View {
        VStack(spacing: Theme.Space.sm * s) {
            // Serif to match the wordmark above it (user call 2026-07-10) — the hero reads as one
            // brand voice from lockup through subheader.
            Text("Run smarter.\nRace faster.")
                .font(.serif(31 * s, weight: .semibold)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center).lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            // Two plain sentences, no dash — the owner's voice rule (2026-07-30): dashes here read
            // as AI-written. Matches the coach-voice no-em-dash bar.
            Text("Plans built by runners, for runners.\nAround your body, your goal, your life.")
                .font(.serif((Theme.FontSize.caption + 2) * s, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                .frame(width: 34, height: 34).momentumGlass(in: Circle())
        }
        .padding(.trailing, Theme.Space.md)
        .accessibilityLabel("Close")
    }
}

/// Staggered entrance for the paywall's sections — opacity + a small rise, never layout. Inert
/// under Reduce Motion (content simply appears).
struct PaywallReveal: ViewModifier {
    let shown: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.55).delay(delay), value: shown)
    }
}

extension View {
    func reveal(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        modifier(PaywallReveal(shown: shown, delay: delay, reduceMotion: reduceMotion))
    }
}

#Preview {
    PaywallView(feature: .aiRead)
        .environment(PaywallController(isPro: false))
}
