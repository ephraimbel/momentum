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
        ("figure.run", "Full multi-discipline plans & daily adaptation"),
        ("chart.xyaxis.line", "Advanced analytics — e1RM, load & trends"),
        ("infinity", "Unlimited history and every share style"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                hero
                benefitList
                plans
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.md)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // Only the CTA is pinned — `safeAreaInset` insets the scroll content above it, so the plans and
        // features are never covered. Everything else flows in one clean column.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Space.sm) {
                cta
                fineprint
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xs)
            .background {
                Theme.background.ignoresSafeArea(edges: .bottom)
                Rectangle().fill(Theme.hairline).frame(height: 0.5).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) { closeButton }
        .interactiveDismissDisabled(working)
        .onAppear { services.analytics.log(.paywallView(placement: feature.placement)) }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: Theme.Space.sm + 2) {
            // Brand lockup: the wordmark + a purple PRO badge — premium, unmistakably ours.
            HStack(spacing: 8) {
                Image("WordmarkBlack").resizable().interpolation(.high).scaledToFit().frame(height: 19)
                Text("PRO").font(.rounded(11, weight: .black)).tracking(1.5).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.purple))
            }
            .accessibilityLabel("Momentum Pro")
            Text("Train smarter,\nevery session.")
                .font(.serif(28, weight: .semibold)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            Text("Unlock \(feature.displayName) — and every Pro feature.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Theme.Space.xs)
    }

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
            ForEach(Self.benefits, id: \.0) { icon, text in
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.purple)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.purple.opacity(0.1)))
                    Text(text).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
    }

    // MARK: Plans

    private var plans: some View {
        VStack(spacing: Theme.Space.sm) {
            planCard(offering.annual, period: .annual,
                     badge: "7-day free trial, then save \(offering.annualSavingsPercent)%")
                .overlay(alignment: .top) {
                    Text("BEST VALUE").font(.rounded(10, weight: .black)).tracking(1.2).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.purple))
                        .offset(y: -9)
                }
            planCard(offering.monthly, period: .monthly, badge: nil)
        }
        .padding(.top, 6)   // room for the floating badge
    }

    private func planCard(_ p: PaywallProduct, period: PaywallProduct.Period, badge: String?) -> some View {
        let isSelected = selected == period
        return Button {
            withAnimation(Motion.lively) { selected = period }
        } label: {
            HStack(spacing: Theme.Space.md) {
                ZStack {
                    Circle().stroke(isSelected ? Theme.purple : Theme.hairline, lineWidth: 2).frame(width: 22, height: 22)
                    if isSelected { Circle().fill(Theme.purple).frame(width: 12, height: 12) }
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
                shape.fill(isSelected ? Theme.purple.opacity(0.06) : Theme.surface)
                shape.stroke(isSelected ? Theme.purple : Theme.hairline, lineWidth: isSelected ? 2 : 1)
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
