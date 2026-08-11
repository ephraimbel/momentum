import Foundation
#if canImport(TikTokBusinessSDK)
import TikTokBusinessSDK
#endif

/// TikTok ads attribution (owner ask 2026-08-11) — the measurement half of running TikTok
/// campaigns: installs/launches auto-report through the SDK, and the two moments the ads are
/// actually optimized on (account created, money committed) are reported here explicitly.
///
/// Doctrine, in the app's own privacy grammar:
///  - **SKAN-only, never ATT.** We never call the tracking-authorization dialog and never touch
///    IDFA — install attribution rides SKAdNetwork (the two TikTok IDs live in Info.plist).
///    Adding an ATT prompt is a deliberate future decision, not a default.
///  - **Config-gated, dark by default** (the Supabase/Mapbox pattern): both Info.plist keys are
///    injected from the untracked `Secrets.xcconfig`; either one empty → `configure()` returns
///    without ever initializing the SDK, and every track call no-ops.
///  - **Hermetic runs stay hermetic**: demo/UI-test launches skip initialization the same way
///    `PaywallController.configure()` skips billing, so screenshots and tests hit no ad network.
@MainActor
enum TikTokAdsService {

    private static var appId: String { Bundle.main.object(forInfoDictionaryKey: "TikTokAppID") as? String ?? "" }
    private static var accessToken: String { Bundle.main.object(forInfoDictionaryKey: "TikTokAccessToken") as? String ?? "" }

    /// True once `configure()` actually initialized the SDK — the gate for every track call.
    private static var isLive = false

    /// Initialize the SDK at launch (call once from `MomentumApp.init`). No-op without credentials.
    static func configure() {
        #if canImport(TikTokBusinessSDK)
        #if DEBUG
        // Same hermeticity contract as billing: a demo/UI-test run must not talk to an ad network.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--seed-demo") || args.contains("--debug-pro") || args.contains("--debug-free")
            || args.contains("--ui-test-route") { return }
        #endif
        guard !appId.isEmpty, !accessToken.isEmpty else { return }
        // `appId` here is the App Store numeric id (Apple's), `tiktokAppId` the Events Manager id.
        guard let config = TikTokConfig(accessToken: accessToken, appId: "6790830947", tiktokAppId: appId) else { return }
        #if DEBUG
        config.debugModeEnabled = true   // sandbox events show in Events Manager's test tab
        #endif
        TikTokBusiness.initializeSdk(config) { success, _ in
            // The SDK calls back off-main; the gate is MainActor state.
            Task { @MainActor in isLive = success }
        }
        #endif
    }

    /// Account created (first cloud session — fresh sign-up or guest upgrade).
    static func trackRegistration() {
        #if canImport(TikTokBusinessSDK)
        guard isLive else { return }
        TikTokBusiness.trackTTEvent(TikTokBaseEvent(eventName: TTEventName.registration.rawValue))
        #endif
    }

    /// A subscription purchase landed. Trial-bearing products report StartTrial (TikTok's
    /// optimization event for free trials), direct purchases report Subscribe; both carry the
    /// localized price so value-based bidding has something to bid on.
    static func trackSubscription(productId: String, isTrial: Bool, price: Decimal?, currency: String?) {
        #if canImport(TikTokBusinessSDK)
        guard isLive else { return }
        let name: TTEventName = isTrial ? .startTrial : .subscribe
        let event = TikTokBaseEvent(eventName: name.rawValue)
        event.addProperty(withKey: "content_id", value: productId)
        if let price { event.addProperty(withKey: "value", value: "\(price)") }
        if let currency { event.addProperty(withKey: "currency", value: currency) }
        TikTokBusiness.trackTTEvent(event)
        #endif
    }
}
