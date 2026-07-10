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

    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selected: PaywallProduct.Period = .annual
    @State private var working = false
    @State private var revealed = false

    private var offering: PaywallOffering { paywall.offering }
    private var product: PaywallProduct { selected == .annual ? offering.annual : offering.monthly }

    /// The FULL list — everything Pro unlocks, one honest line each (Feature enum, spelled out).
    /// Copy is sized to a single row on the smallest supported width — no truncation, ever.
    private static let features: [(String, String)] = [
        ("figure.run", "Your full adaptive training plan"),
        ("brain.head.profile", "Chat with your AI coach"),
        ("text.bubble", "Post-run AI reads"),
        ("gauge.with.needle", "Pace insights & session reviews"),
        ("waveform.path.ecg", "Recovery & injury-aware training"),
        ("flag.checkered", "Race predictions, 5K to marathon"),
        ("chart.xyaxis.line", "Advanced analytics & trends"),
        ("trophy", "Full history & record book"),
        ("speaker.wave.2", "Voice coaching on guided runs"),
        ("metronome", "Cadence metronome"),
        ("applewatch", "Watch premium"),
        ("square.and.arrow.up", "Every share style"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                lockup
                    .padding(.top, Theme.Space.md)
                hero
                    .padding(.top, Theme.Space.lg)
                    .reveal(revealed, delay: 0.05, reduceMotion: reduceMotion)
                featureList
                    .padding(.top, Theme.Space.lg)
                    .reveal(revealed, delay: 0.15, reduceMotion: reduceMotion)
                plans
                    .padding(.top, Theme.Space.lg)
                    .reveal(revealed, delay: 0.25, reduceMotion: reduceMotion)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.md)
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
            .padding(.top, Theme.Space.sm)
            .background {
                // Frosted, not opaque — the iridescent flow stays alive beneath the CTA.
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(edges: .bottom)
                Rectangle().fill(Theme.hairline).frame(height: 0.5).frame(maxHeight: .infinity, alignment: .top)
            }
            .reveal(revealed, delay: 0.32, reduceMotion: reduceMotion)
        }
        .background { flowingBackground }
        .overlay(alignment: .topTrailing) { closeButton }
        .interactiveDismissDisabled(working)
        .onAppear {
            services.analytics.log(.paywallView(placement: feature.placement))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { revealed = true }
        }
    }

    // MARK: Background — the brand's holographic wash, alive but quiet

    /// The animated iridescent mesh flows through the whole canvas, masked so it glows at the top
    /// (behind the lockup + headline), thins where the reading happens, and warms up again under
    /// the plans. Static under Reduce Motion (IridescentView handles it).
    private var flowingBackground: some View {
        ZStack {
            Theme.background
            IridescentView(intensity: 0.5)
                .mask(
                    LinearGradient(stops: [
                        .init(color: .white,                 location: 0.00),
                        .init(color: .white.opacity(0.55),   location: 0.22),
                        .init(color: .white.opacity(0.16),   location: 0.45),
                        .init(color: .white.opacity(0.16),   location: 0.72),
                        .init(color: .white.opacity(0.45),   location: 1.00),
                    ], startPoint: .top, endPoint: .bottom)
                )
        }
        .ignoresSafeArea()
    }

    // MARK: Brand lockup — the wordmark, centered

    private var lockup: some View {
        VStack(spacing: Theme.Space.sm) {
            Image("WordmarkBlack").resizable().interpolation(.high).scaledToFit().frame(height: 24)
            Text("PRO").font(.rounded(11, weight: .black)).tracking(2.2).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 3.5)
                .background(Capsule().fill(Theme.purple))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Momentum Pro")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: Theme.Space.xs + 2) {
            Text("The coach that\nlearns you.")
                .font(.display(34, weight: .bold)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center).lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            Text("Unlock \(feature.displayName) — and everything below.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: The full feature list — everything free is missing

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.features.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: item.0)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 24)
                    Text(item.1)
                        .font(.rounded(14.5, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.82)
                    Spacer(minLength: Theme.Space.sm)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .black)).foregroundStyle(Theme.purple)
                }
                .padding(.vertical, Theme.Space.sm + 1)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .background {
            // A barely-there glass card lifts the list off the wash without deadening it.
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.hairline)
        }
    }

    // MARK: Plans

    private var plans: some View {
        VStack(spacing: Theme.Space.sm) {
            planCard(offering.annual, period: .annual)
            planCard(offering.monthly, period: .monthly)
        }
    }

    private func planCard(_ p: PaywallProduct, period: PaywallProduct.Period) -> some View {
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
                    if p.isAnnual, p.trialDays > 0 {
                        Text("\(p.trialDays)-DAY FREE TRIAL")
                            .font(.rounded(9, weight: .black)).tracking(1.2).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.purple))
                    }
                    Spacer()
                    checkmark(on: isSelected)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(p.priceText)
                        .font(.display(26, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(p.isAnnual ? "/ year" : "/ month")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                Text(p.isAnnual
                     ? "About \(p.perMonthText ?? "$10.00 / mo") · save \(offering.annualSavingsPercent)%"
                     : "No trial · cancel anytime")
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)
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

    private var cta: some View {
        VStack(spacing: Theme.Space.sm) {
            OversizedButton(title: ctaTitle, isEnabled: !working) {
                Task {
                    working = true
                    let ok = await paywall.purchase(product)
                    working = false
                    if ok { services.analytics.log(.paywallConvert(product: product.isAnnual ? "annual" : "monthly")) }
                    if paywall.isPro { dismiss() }
                }
            }
            Button("Restore purchases") {
                Task { working = true; _ = await paywall.restore(); working = false; if paywall.isPro { dismiss() } }
            }
            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
        }
    }

    private var ctaTitle: String {
        if working { return "One moment…" }
        return product.trialDays > 0 ? "Start my \(product.trialDays)-day free trial" : "Continue — \(product.priceText)/month"
    }

    // MARK: Fine print

    private var fineprint: some View {
        VStack(spacing: 6) {
            Text(renewalTerms)
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: Theme.Space.xs) {
                Button("Terms") { open("https://momentum.fit/terms") }
                Text("·").foregroundStyle(Theme.inkTertiary)
                Button("Privacy") { open("https://momentum.fit/privacy") }
            }
            .font(.rounded(Theme.FontSize.label, weight: .semibold))
            .foregroundStyle(Theme.inkTertiary)
        }
        .padding(.top, 2)
    }

    /// Plain-language renewal terms (the §10 honesty bar) — exact wording per plan.
    private var renewalTerms: String {
        if product.isAnnual, product.trialDays > 0 {
            return "Free for \(product.trialDays) days, then \(product.priceText)/year. Cancel anytime in Settings — we’ll remind you before it renews."
        }
        return "\(product.priceText)/month. Cancel anytime in Settings, no questions asked."
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
