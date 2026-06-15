import SwiftUI
#if canImport(RevenueCat)
import RevenueCat
#endif
#if canImport(SuperwallKit)
import SuperwallKit
#endif

/// A subscription product to offer (PRD §10). Price strings come from the store (RevenueCat) once
/// wired; until then these are the PRD's planned prices so the paywall is fully testable offline.
struct PaywallProduct: Identifiable, Sendable, Equatable {
    enum Period: Sendable, Equatable { case monthly, annual }
    let id: String              // RevenueCat / StoreKit product identifier
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

/// API keys for the billing SDKs (PRD §10). Read from Info.plist so they're not in source; empty
/// until set — see docs/MONETIZATION-SETUP.md. Only consulted when the SDKs are linked.
enum BillingKeys {
    static var revenueCat: String { Bundle.main.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String ?? "" }
    static var superwall: String { Bundle.main.object(forInfoDictionaryKey: "SuperwallAPIKey") as? String ?? "" }
}

/// Pro entitlement **and** paywall presentation — the single gating authority for the UI (PRD §10).
/// Conforms to `PaywallServing` so the same instance backs both `services.paywall` (service-layer
/// checks) and `@Environment(PaywallController.self)` (reactive view gating) without divergence.
///
/// Billing runs through RevenueCat when the SDK is linked (entitlement `pro`, offering `default`);
/// otherwise a local, persisted seam keeps gating + the paywall UX fully exercisable offline and in
/// tests. Activation steps: docs/MONETIZATION-SETUP.md.
@MainActor
@Observable
final class PaywallController: PaywallServing {
    static let entitlementKey = "com.momentum.pro.entitled"
    static let entitlementID = "pro"            // RevenueCat entitlement identifier (PRD §10)

    private(set) var isPro: Bool
    /// The locked feature that triggered the paywall — drives the host sheet. `nil` ⇒ not shown.
    var presentedFeature: Feature?
    /// Display offering; replaced with the store's localized prices once `configure()` loads them.
    private(set) var offering: PaywallOffering = .standard

    /// `isPro:` overrides persistence (for tests/previews). Otherwise: entitled in DEBUG demo runs so
    /// Pro surfaces stay visible, else the persisted entitlement (free by default).
    init(isPro override: Bool? = nil) {
        if let override { isPro = override; return }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--debug-free") { isPro = false; return }   // QA the free tier with seeded data
        let demo = args.contains("--seed-demo")
        #else
        let demo = false
        #endif
        isPro = demo || UserDefaults.standard.bool(forKey: Self.entitlementKey)
    }

    /// Configure the billing SDKs at launch. A no-op (local seam) until the SDKs + keys are added.
    func configure() {
        #if canImport(RevenueCat)
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: BillingKeys.revenueCat)
        Task {
            await refreshEntitlement()
            await loadOffering()
            for await info in Purchases.shared.customerInfoStream { apply(info) }   // live entitlement
        }
        #endif
        #if canImport(SuperwallKit)
        Superwall.configure(apiKey: BillingKeys.superwall)
        #endif
    }

    // MARK: Gating (PaywallServing)

    func isEntitled(to feature: Feature) -> Bool { isPro || !feature.requiresPro }

    // MARK: Presentation

    /// Open the paywall for a locked feature (no-op if already entitled). Fires the feature's
    /// Superwall placement (A/B-tested remote paywalls); our `PaywallView` is the in-app fallback.
    func present(for feature: Feature) {
        guard !isEntitled(to: feature) else { return }
        Haptics.light()
        #if canImport(SuperwallKit)
        Superwall.shared.register(placement: feature.placement)
        #endif
        presentedFeature = feature
    }

    func dismiss() { presentedFeature = nil }

    // MARK: Purchase

    /// Buy a product. Returns whether the user ended up entitled.
    func purchase(_ product: PaywallProduct) async -> Bool {
        #if canImport(RevenueCat)
        do {
            guard let package = try await package(for: product) else { return false }
            let result = try await Purchases.shared.purchase(package: package)
            apply(result.customerInfo)
            return isPro
        } catch { return false }   // user-cancelled or store error — caller keeps the paywall up
        #else
        grantLocally()             // local seam: exercise the full unlock flow offline + in tests
        return true
        #endif
    }

    /// Restore prior purchases. Returns whether the user is entitled afterward.
    func restore() async -> Bool {
        #if canImport(RevenueCat)
        if let info = try? await Purchases.shared.restorePurchases() { apply(info) }
        #endif
        return isPro
    }

    // MARK: RevenueCat plumbing (compiled only when the SDK is linked)

    #if canImport(RevenueCat)
    private func refreshEntitlement() async {
        if let info = try? await Purchases.shared.customerInfo() { apply(info) }
    }

    private func loadOffering() async {
        guard let current = try? await Purchases.shared.offerings().current,
              let m = current.monthly?.storeProduct, let a = current.annual?.storeProduct else { return }
        let trial = (a.introductoryDiscount?.paymentMode == .freeTrial)
            ? (a.introductoryDiscount?.subscriptionPeriod.value ?? 7) : 0
        offering = PaywallOffering(
            monthly: .init(id: m.productIdentifier, period: .monthly,
                           priceText: m.localizedPriceString, perMonthText: nil, trialDays: 0),
            annual: .init(id: a.productIdentifier, period: .annual,
                          priceText: a.localizedPriceString, perMonthText: nil, trialDays: trial))
    }

    private func package(for product: PaywallProduct) async -> Package? {
        let current = try? await Purchases.shared.offerings().current
        return current?.availablePackages.first { $0.storeProduct.productIdentifier == product.id }
    }

    private func apply(_ info: CustomerInfo) {
        setPro(info.entitlements[Self.entitlementID]?.isActive == true)
    }
    #endif

    // MARK: Entitlement state

    private func setPro(_ value: Bool) {
        isPro = value
        UserDefaults.standard.set(value, forKey: Self.entitlementKey)
        if value { presentedFeature = nil }
    }

    /// Local-only grant (no SDK): unlocks so the gate → paywall → unlock flow works offline/in tests.
    private func grantLocally() { setPro(true); Haptics.celebration() }

    #if DEBUG
    func resetForTesting() {
        isPro = false
        UserDefaults.standard.removeObject(forKey: Self.entitlementKey)
    }
    #endif
}
