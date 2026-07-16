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
    let priceText: String       // localized total, e.g. "$14.99"
    let perMonthText: String?   // annual only, e.g. "$10.00 / mo"
    let trialDays: Int          // 0 = none

    var isAnnual: Bool { period == .annual }
}

/// The `default` RevenueCat offering: monthly + annual (PRD §10).
struct PaywallOffering: Sendable, Equatable {
    let monthly: PaywallProduct
    let annual: PaywallProduct
    /// Numeric prices behind the display strings — planned by default, replaced with the store's
    /// real values by `loadOffering()` so the savings badge always reflects what's actually charged.
    var monthlyPriceValue: Double = monthlyPrice
    var annualPriceValue: Double = annualPrice

    /// Shipped pricing (decision 2026-07-14, matches the website): $14.99/mo with no trial —
    /// deliberately below Runna's (~$17.99/mo) to win the price-comparison shopper — and $109.99/yr
    /// with a 7-day trial. These two numbers are the **single source**: the monthly/annual
    /// `priceText`, the annual per-month, and `annualSavingsPercent` all derive from them, so the
    /// savings label can never fall out of step with a price change. Live store prices (loadOffering)
    /// replace the display strings once RevenueCat is wired.
    static let monthlyPrice = 14.99
    static let annualPrice = 109.99

    static let standard = PaywallOffering(
        monthly: .init(id: "momentum_pro_monthly", period: .monthly,
                       priceText: money(monthlyPrice), perMonthText: nil, trialDays: 0),
        annual: .init(id: "momentum_pro_annual", period: .annual,
                      priceText: money(annualPrice),
                      perMonthText: "\(money(annualPrice / 12)) / mo", trialDays: 7))

    /// Percent saved by paying yearly instead of 12× monthly, **rounded to the nearest 5%** for a
    /// clean marketing badge (user call 2026-07-14) — derived from the offering's numeric prices
    /// (live once the store loads), never a hand-written label. Currently **40%**: $109.99 vs
    /// 12 × $14.99 = $179.88 is 38.85%, which rounds up to 40%.
    var annualSavingsPercent: Int {
        let monthlyYear = 12 * monthlyPriceValue
        guard monthlyYear > 0 else { return 0 }
        let raw = (monthlyYear - annualPriceValue) / monthlyYear * 100
        return Int((raw / 5).rounded()) * 5   // nearest 5% → a round badge, not "38.85%"
    }

    /// Plain "$14.99" formatting for the offline seam (the live store supplies localized strings).
    static func money(_ v: Double) -> String { "$" + String(format: "%.2f", v) }
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
    static let onboardingGateKey = "com.momentum.pro.onboardingGatePending"

    private(set) var isPro: Bool

    /// True once onboarding reached the hard paywall without a subscription — the app re-presents
    /// the gate on every launch until the athlete is entitled, so force-quitting the paywall is
    /// never a bypass. Cleared the moment any purchase/restore lands.
    var onboardingGatePending: Bool = UserDefaults.standard.bool(forKey: onboardingGateKey) {
        didSet { UserDefaults.standard.set(onboardingGatePending, forKey: Self.onboardingGateKey) }
    }
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
        if args.contains("--debug-pro") { isPro = true; return }     // durable dev unlock (sim daily-driving)
        let demo = args.contains("--seed-demo")
        #else
        let demo = false
        #endif
        isPro = demo || UserDefaults.standard.bool(forKey: Self.entitlementKey)
    }

    /// Configure the billing SDKs at launch. A no-op (local seam) until the SDKs + keys are added.
    func configure() {
        #if DEBUG
        // Demo/UI-test runs are hermetic: with RevenueCat live, `customerInfoStream` would apply the
        // real (un-entitled) sandbox state and STOMP the --seed-demo Pro grant — and StoreKit can pop
        // a sandbox sign-in dialog over screenshots. Demo means no billing network, period.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--seed-demo") || args.contains("--debug-pro")
            || args.contains("--ui-test-route") { return }   // no billing network → no sandbox stomp
        #endif
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
        #if DEBUG
        // Unit tests pin the ENTITLEMENT FLIP, not StoreKit: with RevenueCat linked, the live
        // purchase path tries to present a confirmation sheet inside the headless test host and
        // hangs the suite (no UI anchor + TestTimeoutsEnabled=false). The seam is the contract
        // under test. XCTest classes load only in the unit-test host, never in the shipping app
        // or the XCUITest-driven app process.
        if Self.isRunningUnitTests { grantLocally(); return true }
        #endif
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
        #if DEBUG
        if Self.isRunningUnitTests { return isPro }   // no network in the unit-test host
        #endif
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
        // StoreKit expresses a 7-day trial as (value: 1, unit: .week) — convert to DAYS, or the
        // badge/CTA read "1-day free trial" (shipped-bug class: .value read without .unit).
        let trial: Int = {
            guard let intro = a.introductoryDiscount, intro.paymentMode == .freeTrial else { return 0 }
            let p = intro.subscriptionPeriod
            switch p.unit {
            case .day: return p.value
            case .week: return p.value * 7
            case .month: return p.value * 30
            case .year: return p.value * 365
            @unknown default: return p.value
            }
        }()
        // Annual per-month in the product's own locale/currency (falls back to the plain formatter).
        let perMonth: String = {
            let monthly = a.price / 12
            if let s = a.priceFormatter?.string(from: monthly as NSDecimalNumber) { return "\(s) / mo" }
            return "\(PaywallOffering.money(NSDecimalNumber(decimal: monthly).doubleValue)) / mo"
        }()
        offering = PaywallOffering(
            monthly: .init(id: m.productIdentifier, period: .monthly,
                           priceText: m.localizedPriceString, perMonthText: nil, trialDays: 0),
            annual: .init(id: a.productIdentifier, period: .annual,
                          priceText: a.localizedPriceString, perMonthText: perMonth, trialDays: trial),
            monthlyPriceValue: NSDecimalNumber(decimal: m.price).doubleValue,
            annualPriceValue: NSDecimalNumber(decimal: a.price).doubleValue)
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
        if value {
            presentedFeature = nil
            onboardingGatePending = false   // the hard gate is satisfied — never re-present
        }
    }

    /// Local-only grant (no SDK): unlocks so the gate → paywall → unlock flow works offline/in tests.
    private func grantLocally() { setPro(true); Haptics.celebration() }

    #if DEBUG
    /// True only inside the unit-test host — XCTest loads into that process (Swift Testing runs
    /// hosted in xctest), never into the shipping app or the app under XCUITest.
    private static let isRunningUnitTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    func resetForTesting() {
        isPro = false
        UserDefaults.standard.removeObject(forKey: Self.entitlementKey)
    }
    #endif
}
