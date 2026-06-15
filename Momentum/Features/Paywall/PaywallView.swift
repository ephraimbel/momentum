import SwiftUI

/// The Pro paywall (PRD §10). **Trust is a feature:** two plans, a clear 7-day trial on annual,
/// renewal terms in plain language, one-tap restore. Monochrome with a single iridescent accent on
/// the recommended (annual) plan — the brand's "earned" iridescence.
struct PaywallView: View {
    /// The locked feature that brought the user here — frames the headline.
    var feature: Feature = .aiCoach

    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selected: PaywallProduct.Period = .annual
    @State private var working = false

    private var offering: PaywallOffering { paywall.offering }
    private var product: PaywallProduct { selected == .annual ? offering.annual : offering.monthly }

    private static let benefits: [(String, String)] = [
        ("brain.head.profile", "An adaptive AI coach that learns you"),
        ("calendar", "Full multi-discipline plans, programs & adaptation"),
        ("chart.xyaxis.line", "Advanced analytics — e1RM, training load, trends"),
        ("clock.arrow.circlepath", "Your full history, forever"),
        ("square.and.arrow.up", "Every share style"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                hero
                benefitList
                plans
                cta
                fineprint
            }
            .padding(Theme.Space.lg)
            .padding(.top, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.xl)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) { closeButton }
        .interactiveDismissDisabled(working)
        .onAppear { services.analytics.log(.paywallView(placement: feature.placement)) }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: Theme.Space.md) {
            IridescentOrb(size: 84)
            VStack(spacing: 6) {
                Text("Momentum Pro").font(.display(26, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Unlock \(feature.displayName) and everything below.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            ForEach(Self.benefits, id: \.0) { icon, text in
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 26)
                    Text(text).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Plans

    private var plans: some View {
        VStack(spacing: Theme.Space.sm) {
            planCard(offering.annual, period: .annual,
                     badge: "Save \(offering.annualSavingsPercent)% · 7-day free trial")
            planCard(offering.monthly, period: .monthly, badge: nil)
        }
    }

    private func planCard(_ p: PaywallProduct, period: PaywallProduct.Period, badge: String?) -> some View {
        let isSelected = selected == period
        return Button {
            withAnimation(Motion.lively) { selected = period }
        } label: {
            HStack(spacing: Theme.Space.md) {
                ZStack {
                    Circle().stroke(isSelected ? Theme.ink : Theme.hairline, lineWidth: 2).frame(width: 22, height: 22)
                    if isSelected { Circle().fill(Theme.ink).frame(width: 12, height: 12) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.isAnnual ? "Annual" : "Monthly")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    if let badge {
                        Text(badge).font(.rounded(Theme.FontSize.label, weight: .bold))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(p.priceText).font(.display(18, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(p.isAnnual ? (p.perMonthText ?? "/ yr") : "/ mo")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(Theme.Space.lg)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                shape.fill(Theme.surface)
                if isSelected && p.isAnnual {
                    shape.stroke(IridescentMaterial(), lineWidth: 2)   // earned iridescence on the hero plan
                } else {
                    shape.stroke(isSelected ? Theme.ink : Theme.hairline, lineWidth: isSelected ? 2 : 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: CTA

    private var cta: some View {
        VStack(spacing: Theme.Space.sm) {
            OversizedButton(title: ctaTitle, systemImage: working ? nil : "sparkles", isEnabled: !working) {
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
        if working { return "…" }
        return product.trialDays > 0 ? "Start \(product.trialDays)-day free trial" : "Continue"
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
        .padding(.top, Theme.Space.xs)
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
            Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                .frame(width: 34, height: 34).momentumGlass(in: Circle())
        }
        .padding(Theme.Space.md)
        .accessibilityLabel("Close")
    }

    private func open(_ s: String) { if let url = URL(string: s) { openURL(url) } }
}

#Preview {
    PaywallView(feature: .aiRead)
        .environment(PaywallController(isPro: false))
}
