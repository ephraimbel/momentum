import SwiftUI

/// The Pro paywall (PRD §10) — a full-screen, considered moment, not a sheet. **Trust is a
/// feature:** two plans, the 7-day trial on annual only, renewal terms in plain language before
/// purchase, one-tap restore. Design language is the app's own: near-monochrome on the white
/// canvas, Space Grotesk display type, hairline dividers, `Theme.purple` as the single sanctioned
/// Pro accent — used sparingly, which is what makes it read premium.
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

    /// What Pro actually is — one line each, no marketing fluff. Icons stay ink (monochrome rule).
    private static let benefits: [(String, String, String)] = [
        ("figure.run", "Your full adaptive plan", "Recalibrated after every run — paces, load, recovery."),
        ("waveform.path.ecg", "Coaching intelligence", "AI reads, pace reviews, and voice guidance live."),
        ("shield.lefthalf.filled", "Protective training", "Recovery signals, workload guardrails, the injury loop."),
        ("chart.xyaxis.line", "Advanced analytics", "Race predictions, trends, zones, and full history."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                lockup
                    .padding(.top, Theme.Space.sm)
                hero
                    .padding(.top, Theme.Space.lg)
                    .reveal(revealed, delay: 0.05, reduceMotion: reduceMotion)
                benefitList
                    .padding(.top, Theme.Space.lg)
                    .reveal(revealed, delay: 0.15, reduceMotion: reduceMotion)
                plans
                    .padding(.top, Theme.Space.md)
                    .reveal(revealed, delay: 0.25, reduceMotion: reduceMotion)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.md)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
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
                Theme.background.ignoresSafeArea(edges: .bottom)
                Rectangle().fill(Theme.hairline).frame(height: 0.5).frame(maxHeight: .infinity, alignment: .top)
            }
            .reveal(revealed, delay: 0.32, reduceMotion: reduceMotion)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) { closeButton }
        .interactiveDismissDisabled(working)
        .onAppear {
            services.analytics.log(.paywallView(placement: feature.placement))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { revealed = true }
        }
    }

    // MARK: Brand lockup

    private var lockup: some View {
        HStack(spacing: 8) {
            Image("WordmarkBlack").resizable().interpolation(.high).scaledToFit().frame(height: 18)
            Text("PRO").font(.rounded(10, weight: .black)).tracking(1.6).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Theme.purple))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Momentum Pro")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("The coach that learns you.")
                .font(.display(32, weight: .bold)).foregroundStyle(Theme.ink)
                .lineSpacing(0).fixedSize(horizontal: false, vertical: true)
            Text("Unlock \(feature.displayName) — and everything Pro.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Benefits — hairline editorial rows, monochrome

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.benefits.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                    Image(systemName: item.0)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.1)
                            .font(.rounded(15, weight: .bold)).foregroundStyle(Theme.ink)
                        Text(item.2)
                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Theme.Space.sm + 2)
                .accessibilityElement(children: .combine)
            }
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
                shape.fill(Theme.background)
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
