import SwiftUI

/// The Pro paywall (PRD §10) — full-screen and unmistakably premium (user direction 2026-07-10):
/// the brand's animated iridescence flows softly through the whole canvas, the wordmark sits
/// centered up top, and the FULL feature list spells out everything free is missing. **Trust stays
/// a feature:** two plans, the 7-day trial on annual only, renewal terms in plain language before
/// purchase, one-tap restore. Reduce Motion freezes the flow; legibility always wins (the wash is
/// masked down where text lives).
struct PaywallView: View {
    /// The locked feature that brought the user here — frames the subheadline.
    var feature: Feature = .aiCoach
    /// Hard placement (end of onboarding): no close affordance, no swipe-away — the only ways
    /// forward are starting the trial, subscribing, or restoring. Contextual gates elsewhere stay
    /// dismissible; trust copy (plain renewal terms, one-tap restore) is identical in both modes.
    var hard: Bool = false

    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selected: PaywallProduct.Period = .annual
    @State private var working = false
    @State private var revealed = false
    /// Set when a restore finds nothing to restore — the user gets a plain confirmation rather than
    /// a button that silently does nothing.
    @State private var nothingToRestore = false
    /// Set when a purchase genuinely fails (not when the athlete cancels) — a tap that does nothing
    /// and says nothing is how you lose someone who was trying to pay.
    @State private var purchaseError: String?

    private var offering: PaywallOffering { paywall.offering }
    private var product: PaywallProduct { selected == .annual ? offering.annual : offering.monthly }

    /// Everything Pro unlocks, organized to eight one-liners (related capabilities share a row) so
    /// the whole paywall — list, both plans, CTA — fits one screen with no scroll. Copy is sized to
    /// a single row; no truncation, ever.
    // Held to EIGHT rows so the size-adaptive layout keeps fitting an SE without truncating or
    // scrolling (the scale math is tuned for this count). Fueling joins as a flagship line; the two
    // former utility rows (voice/metronome + watch/share) merge into one to make room.
    private static let features: [(String, String)] = [
        ("figure.run", "Your full adaptive training plan"),
        ("brain.head.profile", "AI coach chat & post-run reads"),
        ("fork.knife", "AI fueling & calorie tracking"),
        ("gauge.with.needle", "Pace insights & session reviews"),
        ("waveform.path.ecg", "Recovery & injury-aware training"),
        ("flag.checkered", "Race predictions, 5K to marathon"),
        ("chart.xyaxis.line", "Analytics, history & records"),
        ("applewatch", "Watch, voice coach & share styles"),
    ]

    var body: some View {
        GeometryReader { geo in
            // One scale drives the whole scrollable stack so the paywall reads *identically* on every
            // iPhone — full-size on a 6.9" Pro Max, gently condensed on a 4.7" SE — instead of the
            // plans getting shoved under the pinned CTA on short screens.
            // Divisor 820: a 6.1" Dynamic-Island phone (iPhone 15/16, ~759pt usable — the Island eats
            // MORE top inset than the 14's notch, so it's the tightest of the "tall" phones) condenses
            // ~7% so the Monthly card clears the pinned CTA with margin; 6.7"+ stays clamped at 1.0
            // (pristine). Paired with the trimmed section paddings below — together they lift Monthly
            // clear without either lever having to over-shrink. Clamped so it never shrinks past legibility.
            let s = min(1, max(0.8, geo.size.height / 820))
            content(s)
        }
    }

    private func content(_ s: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Section gaps trimmed from the original airy spacing (lg/md+2) so the full stack —
                // through the Monthly card — clears the pinned CTA on 6.1" phones. All scale with
                // `s`, so tall phones (s=1) keep breathing room and short ones condense together.
                lockup(s)
                    .padding(.top, Theme.Space.md * s)
                hero(s)
                    .padding(.top, (Theme.Space.sm + 2) * s)
                    .reveal(revealed, delay: 0.05, reduceMotion: reduceMotion)
                featureList(s)
                    .padding(.top, (Theme.Space.md - 2) * s)
                    .reveal(revealed, delay: 0.15, reduceMotion: reduceMotion)
                plans(s)
                    .padding(.top, (Theme.Space.md - 2) * s)
                    .reveal(revealed, delay: 0.25, reduceMotion: reduceMotion)
            }
            .padding(.horizontal, max(Theme.Space.lg, Theme.Space.xl * s))
            .padding(.bottom, Theme.Space.xs)
        }
        .scrollIndicators(.hidden)
        // Only the CTA is pinned — `safeAreaInset` insets the scroll content above it, so the plans
        // and features are never covered.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Space.sm) {
                cta
                fineprint
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.lg)
            // A soft scrim fades the canvas up under the CTA so that on a short screen — where the
            // content can still scroll a hair behind the (chromeless) button — anything passing under
            // it dissolves cleanly instead of peeking through. Invisible on tall phones (nothing
            // scrolls there); ignores the home-indicator inset so the fade reaches the very bottom.
            .background {
                LinearGradient(colors: [.clear, Theme.background.opacity(0.9), Theme.background],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .reveal(revealed, delay: 0.32, reduceMotion: reduceMotion)
        }
        .background { flowingBackground }
        .overlay(alignment: .topTrailing) { if !hard { closeButton } }
        // The paywall is a dark, cinematic moment regardless of the athlete's appearance setting
        // (user call 2026-07-10) — the wash reads best over true black. Use `.environment(\.colorScheme)`,
        // NOT `.preferredColorScheme`: the latter is a PREFERENCE that flows UP to the hosting window,
        // so on dismiss it left the presenter (e.g. the coach chat) stuck in dark. Setting the
        // environment styles only the paywall's own subtree — same dark look, no leak to whoever
        // presented it.
        .environment(\.colorScheme, .dark)
        .alert("Nothing to restore", isPresented: $nothingToRestore) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We couldn't find a past purchase on this Apple ID.")
        }
        // Cancellation stays silent — this only fires on a real failure, and always offers Restore,
        // since "charged but not entitled" is the case where saying nothing is worst.
        .alert("Purchase didn't go through",
               isPresented: Binding(get: { purchaseError != nil },
                                    set: { if !$0 { purchaseError = nil } })) {
            Button("Try again") { purchaseError = nil }
            Button("Restore") {
                purchaseError = nil
                Task {
                    working = true; _ = await paywall.restore(); working = false
                    if paywall.isPro { dismiss() } else { nothingToRestore = true }
                }
            }
            Button("Not now", role: .cancel) { purchaseError = nil }
        } message: {
            Text(purchaseError ?? "")
        }
        .interactiveDismissDisabled(working || hard)
        .onAppear {
            services.analytics.log(.paywallView(placement: feature.placement))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { revealed = true }
        }
    }

    // MARK: Background — the brand's holographic wash, alive but quiet

    /// The animated iridescent mesh flows through the whole canvas — alive enough to notice, masked
    /// so it glows at the top (behind the lockup + headline), stays present behind the reading, and
    /// warms up again under the plans. Static under Reduce Motion (IridescentView handles it).
    private var flowingBackground: some View {
        ZStack {
            Theme.background
            IridescentView(intensity: 0.72)
                .mask(
                    LinearGradient(stops: [
                        .init(color: .white,                 location: 0.00),
                        .init(color: .white.opacity(0.70),   location: 0.22),
                        .init(color: .white.opacity(0.34),   location: 0.45),
                        .init(color: .white.opacity(0.34),   location: 0.72),
                        .init(color: .white.opacity(0.60),   location: 1.00),
                    ], startPoint: .top, endPoint: .bottom)
                )
        }
        .ignoresSafeArea()
    }

    // MARK: Brand lockup — the wordmark, centered

    private func lockup(_ s: CGFloat) -> some View {
        VStack(spacing: Theme.Space.sm * s) {
            // Always the white wordmark — this surface is permanently dark.
            Image("WordmarkWhite")
                .resizable().interpolation(.high).scaledToFit().frame(height: 22 * s)
            Text("PRO").font(.rounded(11, weight: .black)).tracking(2.2).foregroundStyle(Color(hex: "0E0E12"))
                .padding(.horizontal, 10).padding(.vertical, 3.5)
                .background(Capsule().fill(Theme.route))
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
            Text("The full adaptive engine, built around\nyour body, your goal, your life.")
                .font(.serif((Theme.FontSize.caption + 2) * s, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: The full feature list — everything free is missing

    private func featureList(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.features.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                // Tighter internal chrome than the design width so the full copy fits even on a
                // 4.7" SE without truncating; `minimumScaleFactor` is the last-ditch safety net.
                HStack(spacing: Theme.Space.sm + 2) {
                    Image(systemName: item.0)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 22)
                    Text(item.1)
                        .font(.rounded(14, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: Theme.Space.xs)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .black)).foregroundStyle(Theme.route)
                }
                .padding(.vertical, (Theme.Space.sm + 1) * s)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .background {
            // A barely-there glass card lifts the list off the wash without deadening it.
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.hairline)
        }
    }

    // MARK: Plans

    private func plans(_ s: CGFloat) -> some View {
        VStack(spacing: Theme.Space.sm * s) {
            planCard(offering.annual, period: .annual, s: s)
            planCard(offering.monthly, period: .monthly, s: s)
        }
    }

    private func planCard(_ p: PaywallProduct, period: PaywallProduct.Period, s: CGFloat) -> some View {
        let isSelected = selected == period
        return Button {
            guard selected != period else { return }
            Haptics.light()
            withAnimation(Motion.lively) { selected = period }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(p.isAnnual ? "Annual" : "Monthly")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).tracking(0.4)
                        .foregroundStyle(Theme.inkSecondary)
                    // Suppressed with the price: the trial length is a placeholder until the store
                    // answers, and "7-DAY FREE TRIAL" is as much a promise as the number beside it.
                    if p.isAnnual, p.trialDays > 0, paywall.pricingIsLive {
                        Text("\(p.trialDays)-DAY FREE TRIAL")
                            .font(.rounded(9, weight: .black)).tracking(1.2).foregroundStyle(Color(hex: "0E0E12"))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.route))
                    }
                    Spacer()
                    checkmark(on: isSelected)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Never present a placeholder as the price. Until the store's offering lands,
                    // `p.priceText` is a US-dollar constant that would be wrong for any other
                    // storefront and would survive a price change — so show a dash instead.
                    Text(paywall.pricingIsLive ? p.priceText : "—")
                        .font(.display(23, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(p.isAnnual ? "/ year" : "/ month")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    Spacer()
                    Text(pricingAside(p))
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, (Theme.Space.sm + 3) * s)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                shape.fill(.ultraThinMaterial)
                shape.stroke(isSelected ? Theme.ink : Theme.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(isSelected ? "" : "Selects the \(p.isAnnual ? "annual" : "monthly") plan")
    }

    private func checkmark(on: Bool) -> some View {
        ZStack {
            Circle().stroke(on ? Theme.ink : Theme.hairline, lineWidth: 1.5)
            if on {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .black)).foregroundStyle(Theme.background)
                    .frame(width: 22, height: 22).background(Circle().fill(Theme.ink))
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
        }
        .frame(width: 22, height: 22)
    }

    // MARK: CTA

    /// Compact primary action — 48pt, quieter than the 56pt OversizedButton so the plans above
    /// keep the visual weight.
    private var cta: some View {
        Button {
            Haptics.light()
            Task {
                working = true
                // Pricing not live means `offering` is still placeholders — there is no real
                // package to buy, so retry the fetch instead of firing a purchase that can only
                // fail. Succeeds → the athlete taps again and buys at the store's real price.
                guard paywall.pricingIsLive else {
                    await paywall.reloadPricing()
                    working = false
                    if !paywall.pricingIsLive {
                        purchaseError = "We couldn't load pricing from the App Store. Check your connection and try again."
                    }
                    return
                }
                let outcome = await paywall.purchase(product)
                working = false
                switch outcome {
                case .purchased:
                    services.analytics.log(.paywallConvert(product: product.isAnnual ? "annual" : "monthly"))
                case .cancelled:
                    break                                   // they changed their mind — say nothing
                case .failed(let message):
                    purchaseError = message
                }
                if paywall.isPro { dismiss() }
            }
        } label: {
            Text(ctaTitle)
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 48)
                .foregroundStyle(Theme.background)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
        }
        .buttonStyle(.plain)
        .opacity(working ? 0.4 : 1)
        .disabled(working)
    }

    /// The right-hand note on a plan row. Suppressed with the price — a savings percentage computed
    /// from placeholder numbers is just as wrong as the numbers themselves.
    private func pricingAside(_ p: PaywallProduct) -> String {
        guard paywall.pricingIsLive else { return "Pricing unavailable" }
        return p.isAnnual
            ? "≈ \(p.perMonthText ?? PaywallOffering.standard.annual.perMonthText ?? "") · save \(offering.annualSavingsPercent)%"
            : "No trial · cancel anytime"
    }

    private var ctaTitle: String {
        if working { return "One moment…" }
        // Don't quote a price we haven't confirmed with the store, and don't promise a trial length
        // that came from a placeholder either.
        guard paywall.pricingIsLive else { return "Retry" }
        return product.trialDays > 0 ? "Start my \(product.trialDays)-day free trial" : "Continue — \(product.priceText)\(product.isAnnual ? "/year" : "/month")"
    }

    // MARK: Fine print

    /// One tiny line: honest renewal terms + the required links, nothing taller.
    private var fineprint: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(renewalTerms)
            Text("·")
            Button("Restore") {
                Task {
                    working = true; _ = await paywall.restore(); working = false
                    if paywall.isPro { dismiss() } else { nothingToRestore = true }
                }
            }
            Text("·")
            Button("Terms") { open("https://momentumco.app/terms") }
            Text("·")
            Button("Privacy") { open("https://momentumco.app/privacy") }
        }
        .font(.rounded(10, weight: .medium))
        .foregroundStyle(Theme.inkTertiary)
        .lineLimit(1).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }

    /// Plain-language renewal terms (the §10 honesty bar), one short line per plan.
    private var renewalTerms: String {
        // The fine print is the one place a wrong number is actually a claim about what we'll
        // charge — never build it from placeholder pricing.
        guard paywall.pricingIsLive else { return "Pricing unavailable · cancel anytime" }
        if product.isAnnual, product.trialDays > 0 {
            return "\(product.trialDays) days free, then \(product.priceText)/yr · cancel anytime"
        }
        return "\(product.priceText)/mo · cancel anytime"
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                .frame(width: 34, height: 34).momentumGlass(in: Circle())
        }
        .padding(.trailing, Theme.Space.md)
        .accessibilityLabel("Close")
    }

    private func open(_ s: String) { if let url = URL(string: s) { openURL(url) } }
}

/// Staggered entrance for the paywall's sections — opacity + a small rise, never layout. Inert
/// under Reduce Motion (content simply appears).
private struct PaywallReveal: ViewModifier {
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

private extension View {
    func reveal(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        modifier(PaywallReveal(shown: shown, delay: delay, reduceMotion: reduceMotion))
    }
}

#Preview {
    PaywallView(feature: .aiRead)
        .environment(PaywallController(isPro: false))
}
