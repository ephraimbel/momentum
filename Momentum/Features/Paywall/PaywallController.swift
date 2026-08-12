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

/// What came of a purchase attempt. `cancelled` is a normal, silent outcome — the athlete closed
/// the sheet. `failed` carries a sentence worth showing them.
enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    case cancelled
    case failed(String)
}

/// The `default` RevenueCat offering: monthly + annual (PRD §10).
struct PaywallOffering: Sendable, Equatable {
    let monthly: PaywallProduct
    let annual: PaywallProduct
    /// Numeric prices behind the display strings — planned by default, replaced with the store's
    /// real values by `loadOffering()` so the savings badge always reflects what's actually charged.
    var monthlyPriceValue: Double = monthlyPrice
    var annualPriceValue: Double = annualPrice

    /// Shipped pricing (decision 2026-07-29, matches the website): $9.99/mo with no trial and
    /// $59.99/yr with a 7-day free trial (trial on ANNUAL ONLY — owner call 2026-07-30; the trial
    /// is the annual's nudge, monthly stays the plain commitment-free option). Deliberately
    /// mass-market — half Runna's annual (~$119.99), a notch under Strava's (~$79.99) — because the
    /// hard paywall makes the annual price the conversion funnel; the marketing line is "a full
    /// adaptive plan for under $5 a month". These two numbers are the **single source**: the
    /// monthly/annual `priceText`, the annual per-month, and `annualSavingsPercent` all derive from
    /// them, so the savings label can never fall out of step with a price change. Live store prices
    /// (loadOffering) replace the display strings once RevenueCat is wired.
    static let monthlyPrice = 9.99
    static let annualPrice = 59.99

    static let standard = PaywallOffering(
        monthly: .init(id: "momentum_pro_monthly", period: .monthly,
                       priceText: money(monthlyPrice), perMonthText: nil, trialDays: 0),
        annual: .init(id: "momentum_pro_annual", period: .annual,
                      priceText: money(annualPrice),
                      perMonthText: "\(money(annualPrice / 12)) / mo", trialDays: 7))

    /// Percent saved by paying yearly instead of 12× monthly, **rounded to the nearest 5%** for a
    /// clean marketing badge (user call 2026-07-14) — derived from the offering's numeric prices
    /// (live once the store loads), never a hand-written label. Currently **50%**: $59.99 vs
    /// 12 × $9.99 = $119.88 is 49.96%, which rounds to 50%.
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
    /// DEBUG-only dev unlock (see init) — never read in Release.
    static let devUnlockKey = "com.momentum.pro.devUnlock"
    static let entitlementID = "pro"            // RevenueCat entitlement identifier (PRD §10)
    static let onboardingGateKey = "com.momentum.pro.onboardingGatePending"

    private(set) var isPro: Bool

    /// When the billing identity last changed. Since 2026-07-27 the account is asked for at the END
    /// of onboarding, so **every** onboarding purchase is made by an anonymous RevenueCat customer
    /// and identified afterwards. Logging in from an anonymous id to one RevenueCat has never seen
    /// aliases and transfers the purchase; logging in to one it already knows (a reinstall, a second
    /// device) does not — that customer's info carries no entitlement, and RevenueCat delivers it
    /// twice (logIn's return *and* `customerInfoStream`). Believing either would lock out an athlete
    /// who just paid. Keyed on the identity change rather than the purchase, so it covers a Restore
    /// just as well, and however long the athlete deferred signing in. See `apply`.
    private var identityChangedAt: Date?
    /// A receipt reconciliation is deciding the entitlement — hold off on downgrading until it does.
    private var reconciling = false

    /// True once onboarding reached the hard paywall without a subscription — the app re-presents
    /// the gate on every launch until the athlete is entitled, so force-quitting the paywall is
    /// never a bypass. Cleared the moment any purchase/restore lands.
    var onboardingGatePending: Bool = UserDefaults.standard.bool(forKey: onboardingGateKey) {
        didSet { UserDefaults.standard.set(onboardingGatePending, forKey: Self.onboardingGateKey) }
    }
    /// The locked feature that triggered the paywall — drives the host sheet. `nil` ⇒ not shown.
    var presentedFeature: Feature?

    /// A HARD gate was let go because the App Store could not be reached (see `PaywallView`'s
    /// store-unreachable escape). Deliberately **not persisted** and never written to
    /// `onboardingGatePending`: the athlete gets this launch, and the wall comes straight back on the
    /// next one. Without it, an athlete who finished onboarding offline — or during a StoreKit /
    /// RevenueCat outage, or against a mis-configured offering — had no purchase to make, no receipt
    /// to restore, and no way to close the wall. The app was simply unusable, and force-quitting only
    /// re-raised the same gate. That is also exactly the state an App Review device on a flaky
    /// network lands in, which is a 2.1 rejection.
    var storeUnreachableDeferral = false
    /// Display offering; replaced with the store's localized prices once `configure()` loads them.
    private(set) var offering: PaywallOffering = .standard

    /// Whether `offering` holds the STORE's prices rather than the built-in placeholders.
    ///
    /// This matters because the placeholders are US dollars. If the offering fails to load — no
    /// network, a misconfigured offering, a missing package — the paywall would otherwise present
    /// "$14.99" to someone whose storefront charges euros, and would keep presenting it after any
    /// future price change. Showing a number we can't stand behind is the one thing this brand
    /// doesn't do, and Apple expects accurate pricing besides. The view suppresses prices and
    /// offers a retry while this is false.
    private(set) var pricingIsLive = false

    /// `isPro:` overrides persistence (for tests/previews). Otherwise: entitled in DEBUG demo runs so
    /// Pro surfaces stay visible, else the persisted entitlement (free by default).
    init(isPro override: Bool? = nil) {
        if let override { isPro = override; return }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        // The dev flags PERSIST via their own key (one --debug-pro launch unlocks the install for
        // good; --debug-free clears it). A separate key, deliberately: the REAL entitlement key
        // belongs to RevenueCat reconciliation, which on every plain launch applies the sandbox
        // account's (un-entitled) truth — writing the real key here lasted exactly one launch
        // before the SDK stomped it back to free. The dev key also short-circuits `configure()`,
        // so the billing SDK never runs on a dev-unlocked install.
        if args.contains("--debug-free") {
            UserDefaults.standard.set(false, forKey: Self.devUnlockKey)
            UserDefaults.standard.set(false, forKey: Self.entitlementKey)
            isPro = false; return
        }
        if args.contains("--debug-pro") {
            UserDefaults.standard.set(true, forKey: Self.devUnlockKey)
            isPro = true; return
        }
        if UserDefaults.standard.bool(forKey: Self.devUnlockKey) { isPro = true; return }
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
        // Screenshot seam for the pricing-unavailable state — the branch a real athlete lands on
        // when the store can't be reached. It is otherwise unreachable on a simulator, and an
        // unverified error state is how you ship a broken-looking one.
        if args.contains("--paywall-pricing-down") { pricingIsLive = false; return }
        // Hermetic runs never reach the store, so the placeholder prices ARE the intended truth
        // here — mark pricing live or the marketing-screenshot builds would render the retry state.
        // `--debug-free` belongs here for the same reason as the rest: a run that forces the FREE
        // tier is a run about the paywall, and reaching the real store means the trial CTA opens a
        // StoreKit sandbox sheet no UI test can answer (and that lands over screenshots). Forced-free
        // + the local purchase seam is what makes the gate → purchase → unlock path testable at all.
        if args.contains("--seed-demo") || args.contains("--debug-pro") || args.contains("--debug-free")
            || args.contains("--ui-test-route") { pricingIsLive = true; return }   // no billing network → no sandbox stomp
        // A dev-unlocked install (persisted --debug-pro) is hermetic on EVERY launch, not just
        // flagged ones — otherwise the first plain launch reconciles the sandbox account's
        // un-entitled truth over the deliberate dev grant.
        if UserDefaults.standard.bool(forKey: Self.devUnlockKey) { pricingIsLive = true; return }
        #endif
        #if canImport(RevenueCat)
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: BillingKeys.revenueCat)
        Task {
            await refreshEntitlement()
            await loadOffering()
            for await info in Purchases.shared.customerInfoStream { apply(info) }   // live entitlement
        }
        #else
        pricingIsLive = true   // local seam (SDK not linked): the PRD prices are all there is
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

    /// Buy a product.
    ///
    /// Returns an outcome rather than a Bool: this used to collapse "the athlete changed their
    /// mind" and "the store failed" into the same `false`, and the caller — having no way to tell
    /// them apart — stayed silent for both. The failure case was a dead button. Someone trying to
    /// pay tapped, the spinner stopped, and nothing happened or explained itself.
    func purchase(_ product: PaywallProduct) async -> PurchaseOutcome {
        #if DEBUG
        // Unit tests pin the ENTITLEMENT FLIP, not StoreKit: with RevenueCat linked, the live
        // purchase path tries to present a confirmation sheet inside the headless test host and
        // hangs the suite (no UI anchor + TestTimeoutsEnabled=false). The seam is the contract
        // under test. XCTest classes load only in the unit-test host, never in the shipping app
        // or the XCUITest-driven app process.
        if Self.isRunningUnitTests { grantLocally(); return .purchased }
        #endif
        #if canImport(RevenueCat)
        // The SDK is LINKED but `configure()` deliberately skips it on hermetic runs (--seed-demo,
        // --debug-pro, --ui-test-route, a dev-unlocked install). `Purchases.shared` traps when it was
        // never configured, so tapping the CTA on those runs crashed the app outright — an annoyance
        // when the paywall was dismissible, a permanent lockout now that onboarding's is hard. Fall
        // back to the same local seam used when the SDK isn't linked at all. Release never grants:
        // an unconfigured SDK there is a real failure, not a test seam.
        guard Purchases.isConfigured else {
            #if DEBUG
            grantLocally(); return .purchased
            #else
            return .failed("We couldn't reach the App Store. Check your connection and try again.")
            #endif
        }
        do {
            guard let package = try await package(for: product) else {
                // No matching package means the offering never loaded — the prices on screen are
                // placeholders and there is nothing to actually buy. Say so.
                return .failed("We couldn't reach the App Store. Check your connection and try again.")
            }
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return .cancelled }
            apply(result.customerInfo)
            // The money moment TikTok campaigns bid on — only when the entitlement actually
            // landed, so a deferred/pending payment never reports revenue that didn't happen.
            if isPro {
                TikTokAdsService.trackSubscription(productId: product.id,
                                                   isTrial: product.trialDays > 0,
                                                   price: package.storeProduct.price,
                                                   currency: package.storeProduct.currencyCode)
                // The same moment through Apple's framework, which reaches the ad network even
                // with every SDK dark (see SKANConversion).
                SKANConversion.record(product.trialDays > 0 ? .trialStarted : .subscribed)
            }
            // Purchase reported success but the entitlement didn't land (deferred/pending payment,
            // Ask to Buy). Point at Restore rather than leaving them staring at a locked app.
            return isPro ? .purchased
                         : .failed("That didn't complete. If you were charged, tap Restore.")
        } catch {
            // RevenueCat throws a cancellation for some store paths and reports it via
            // `userCancelled` on others — handle both or a dismissed sheet reads as an error.
            let ns = error as NSError
            if ns.domain == ErrorCode.errorDomain,
               ns.code == ErrorCode.purchaseCancelledError.rawValue { return .cancelled }
            return .failed(ns.localizedDescription)
        }
        #else
        grantLocally()             // local seam: exercise the full unlock flow offline + in tests
        return .purchased
        #endif
    }

    /// Re-fetch the store's offering. The paywall calls this to retry after a pricing failure.
    func reloadPricing() async {
        #if canImport(RevenueCat)
        guard Purchases.isConfigured else { return }
        await loadOffering()
        #endif
    }

    /// Restore prior purchases. Returns whether the user is entitled afterward.
    func restore() async -> Bool {
        #if DEBUG
        if Self.isRunningUnitTests { return isPro }   // no network in the unit-test host
        #endif
        #if canImport(RevenueCat)
        // Same trap as `purchase`: Restore is the OTHER way out of the hard gate, so it must never
        // be the thing that crashes an athlete who already paid.
        if Purchases.isConfigured,
           let info = try? await Purchases.shared.restorePurchases() { apply(info) }
        #endif
        return isPro
    }

    /// Tie RevenueCat's customer record to the athlete's account, or release it back to anonymous.
    ///
    /// Without this the SDK mints a random anonymous App User ID per install, which has three
    /// consequences: a reinstall reads as a brand-new customer (inflating new-customer counts and
    /// breaking cohort/retention numbers), entitlement only follows the athlete across devices via a
    /// manual Restore tap, and RevenueCat's revenue data can't be joined to our own `app_events`
    /// funnel or to a Supabase user — so "which placement actually converts" stays unanswerable on
    /// the revenue side. Pass the real Apple user id on sign-in; pass nil for guests and sign-out.
    ///
    /// Aliasing is RevenueCat's documented behaviour: logging in from an anonymous id transfers that
    /// id's purchases onto the identified customer, so an athlete who bought before signing in keeps
    /// what they paid for.
    func identify(userID: String?) {
        #if canImport(RevenueCat)
        guard Purchases.isConfigured else { return }   // hermetic DEBUG paths never configured the SDK
        identityChangedAt = Date()   // arms the anti-downgrade reconciliation in `apply`
        Task {
            if let userID {
                if let result = try? await Purchases.shared.logIn(userID) { apply(result.customerInfo) }
            } else {
                if let info = try? await Purchases.shared.logOut() { apply(info) }
            }
        }
        #endif
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
        // Read per-product, never hardcoded: the store is the truth for which plan carries an
        // offer (today: annual only), and a hardcoded 0 is exactly how a store-side offer would
        // silently never display.
        func trialDays(of product: StoreProduct) -> Int {
            guard let intro = product.introductoryDiscount, intro.paymentMode == .freeTrial else { return 0 }
            let p = intro.subscriptionPeriod
            switch p.unit {
            case .day: return p.value
            case .week: return p.value * 7
            case .month: return p.value * 30
            case .year: return p.value * 365
            @unknown default: return p.value
            }
        }
        // Annual per-month in the product's own locale/currency (falls back to the plain formatter).
        let perMonth: String = {
            let monthly = a.price / 12
            if let s = a.priceFormatter?.string(from: monthly as NSDecimalNumber) { return "\(s) / mo" }
            return "\(PaywallOffering.money(NSDecimalNumber(decimal: monthly).doubleValue)) / mo"
        }()
        offering = PaywallOffering(
            monthly: .init(id: m.productIdentifier, period: .monthly,
                           priceText: m.localizedPriceString, perMonthText: nil, trialDays: trialDays(of: m)),
            annual: .init(id: a.productIdentifier, period: .annual,
                          priceText: a.localizedPriceString, perMonthText: perMonth, trialDays: trialDays(of: a)),
            monthlyPriceValue: NSDecimalNumber(decimal: m.price).doubleValue,
            annualPriceValue: NSDecimalNumber(decimal: a.price).doubleValue)
        pricingIsLive = true   // only now are the numbers on screen the store's
    }

    private func package(for product: PaywallProduct) async -> Package? {
        let current = try? await Purchases.shared.offerings().current
        return current?.availablePackages.first { $0.storeProduct.productIdentifier == product.id }
    }

    /// `authoritative` = this info came from re-reading the device receipt, so it decides, full stop.
    private func apply(_ info: CustomerInfo, authoritative: Bool = false) {
        let active = info.entitlements[Self.entitlementID]?.isActive == true
        // An identity change must never take Pro away — see `identityChangedAt`. `setPro(false)`
        // persists to `entitlementKey`, which `SiriMealLogger` reads out-of-process too, so a wrong
        // downgrade silently breaks more than the paywall. The receipt is the arbiter: restore and
        // apply whatever it actually says. Ordinary expiry (no identity change in play) is untouched
        // and still downgrades immediately.
        if !active, isPro, !authoritative {
            if reconciling { return }   // a reconciliation is already deciding this
            if let changed = identityChangedAt, Date().timeIntervalSince(changed) < 120 {
                reconciling = true
                Task {
                    defer { reconciling = false }
                    if let receipt = try? await Purchases.shared.restorePurchases() {
                        apply(receipt, authoritative: true)
                    }
                }
                return
            }
        }
        setPro(active)
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
