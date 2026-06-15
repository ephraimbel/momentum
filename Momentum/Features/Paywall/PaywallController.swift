import SwiftUI

/// A subscription product to offer (PRD §10). Price strings come from the store once RevenueCat is
/// wired; until then these are the PRD's planned prices so the paywall is fully testable offline.
struct PaywallProduct: Identifiable, Sendable, Equatable {
    enum Period: Sendable, Equatable { case monthly, annual }
    let id: String              // RevenueCat product identifier
    let period: Period
    let priceText: String       // localized total, e.g. "$59.99"
    let perMonthText: String?   // annual only, e.g. "$5.00 / mo"
    let trialDays: Int          // 0 = none

    var isAnnual: Bool { period == .annual }
}

/// The `default` RevenueCat offering: monthly + annual (PRD §10).
struct PaywallOffering: Sendable, Equatable {
    let monthly: PaywallProduct
    let annual: PaywallProduct

    /// PRD §10 planned pricing — used until the live store supplies localized prices.
    static let standard = PaywallOffering(
        monthly: .init(id: "momentum_pro_monthly", period: .monthly,
                       priceText: "$9.99", perMonthText: nil, trialDays: 0),
        annual: .init(id: "momentum_pro_annual", period: .annual,
                      priceText: "$59.99", perMonthText: "$5.00 / mo", trialDays: 7))

    /// "Save 50%" vs paying monthly for a year — shown on the annual plan.
    var annualSavingsPercent: Int {
        let monthlyYear = 12 * 9.99, annualYear = 59.99
        guard monthlyYear > 0 else { return 0 }
        return Int(((monthlyYear - annualYear) / monthlyYear * 100).rounded())
    }
}

/// Pro entitlement **and** paywall presentation — the single gating authority for the UI (PRD §10).
/// Conforms to `PaywallServing` so the same instance can back both `services.paywall` (service-layer
/// checks) and `@Environment(PaywallController.self)` (reactive view gating) without divergence.
/// Entitlement persists locally; `purchase`/`restore` are seamed for RevenueCat (a later slice).
@MainActor
@Observable
final class PaywallController: PaywallServing {
    static let entitlementKey = "com.momentum.pro.entitled"

    private(set) var isPro: Bool
    /// The locked feature that triggered the paywall — drives the host sheet. `nil` ⇒ not shown.
    var presentedFeature: Feature?
    let offering = PaywallOffering.standard

    /// `isPro:` overrides persistence (for tests/previews). Otherwise: entitled in DEBUG demo runs so
    /// Pro surfaces stay visible, else the persisted entitlement (free by default).
    init(isPro override: Bool? = nil) {
        if let override { isPro = override; return }
        #if DEBUG
        let demo = ProcessInfo.processInfo.arguments.contains("--seed-demo")
        #else
        let demo = false
        #endif
        isPro = demo || UserDefaults.standard.bool(forKey: Self.entitlementKey)
    }

    // MARK: Gating (PaywallServing)

    func isEntitled(to feature: Feature) -> Bool { isPro || !feature.requiresPro }

    // MARK: Presentation

    /// Open the paywall for a locked feature (no-op if already entitled). A later slice also fires
    /// the Superwall placement `feature.placement` here for A/B-tested paywalls.
    func present(for feature: Feature) {
        guard !isEntitled(to: feature) else { return }
        Haptics.light()
        presentedFeature = feature
    }

    func dismiss() { presentedFeature = nil }

    // MARK: Purchase — RevenueCat seam

    /// Buy a product. Returns whether the user ended up entitled.
    func purchase(_ product: PaywallProduct) async -> Bool {
        // TODO(Phase 3 — RevenueCat): `Purchases.shared.purchase(package)` then read the `pro`
        // entitlement. Until the SDK + App Store Connect products land, grant locally so the full
        // gate → paywall → unlock flow is exercisable offline and in tests.
        grant()
        return true
    }

    /// Restore prior purchases. Returns whether the user is entitled afterward.
    func restore() async -> Bool {
        // TODO(Phase 3 — RevenueCat): `Purchases.shared.restorePurchases()`.
        return isPro
    }

    private func grant() {
        isPro = true
        UserDefaults.standard.set(true, forKey: Self.entitlementKey)
        presentedFeature = nil
        Haptics.celebration()
    }

    #if DEBUG
    func resetForTesting() {
        isPro = false
        UserDefaults.standard.removeObject(forKey: Self.entitlementKey)
    }
    #endif
}
