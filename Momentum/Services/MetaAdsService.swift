import Foundation
#if canImport(FBSDKCoreKit)
import FBSDKCoreKit
#endif

/// Meta (Facebook/Instagram) ads attribution — the second ad network, wired 2026-08-11 to the
/// same config-gated doctrine as [`TikTokAdsService`], with Meta's optional advertiser-ID path
/// protected by App Tracking Transparency:
///
///  - **SKAN always, IDFA only after consent.** Install attribution rides SKAdNetwork and
///    Aggregated Event Measurement without ATT; `AdTrackingConsent` enables advertiser-ID
///    collection only after the athlete authorizes it.
///  - **Config-gated, dark by default**: `FacebookAppID`/`FacebookClientToken` are injected from the
///    untracked `Secrets.xcconfig`; either empty → `configure()` never initializes the SDK. Since
///    SDK v9 there is no auto-init, so an un-called SDK is genuinely inert.
///  - **Hermetic runs stay hermetic**: demo/UI-test launches skip initialization entirely.
///
/// Event split differs from TikTok deliberately: Meta's SDK observes StoreKit itself and
/// auto-logs purchases/subscriptions/trials (IAPEventResolver) when auto app events are on, so
/// manually logging them here would double-count revenue. We hand-log only the one moment the
/// SDK cannot infer — account creation.
@MainActor
enum MetaAdsService {

    private static var appId: String { Bundle.main.object(forInfoDictionaryKey: "FacebookAppID") as? String ?? "" }
    private static var clientToken: String { Bundle.main.object(forInfoDictionaryKey: "FacebookClientToken") as? String ?? "" }

    /// True once `configure()` actually initialized the SDK — the gate for every track call.
    private static var isLive = false

    /// Initialize the SDK at launch (call once from `MomentumApp.init`). No-op without credentials.
    static func configure() {
        #if canImport(FBSDKCoreKit)
        #if DEBUG
        // Same hermeticity contract as billing: a demo/UI-test run must not talk to an ad network.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--seed-demo") || args.contains("--debug-pro") || args.contains("--debug-free")
            || args.contains("--ui-test-route") { return }
        #endif
        guard !appId.isEmpty, !clientToken.isEmpty else { return }
        // ATT has not been answered yet this launch, so start with the advertiser ID OFF: the SDK
        // must never be in a position to read the IDFA before the athlete has seen the prompt.
        // `AdTrackingConsent` turns these back on only if they allow tracking (and re-applies the
        // stored answer on later launches). iOS already zeroes the IDFA without authorization, but
        // setting it explicitly is what an App Review pass should see, and it keeps the SDK honest
        // if Apple's own gate ever loosens.
        Settings.shared.isAdvertiserIDCollectionEnabled = false
        ApplicationDelegate.shared.initializeSDK()
        isLive = true
        #endif
    }

    /// Account created (first cloud session — fresh sign-up or guest upgrade).
    static func trackRegistration() {
        #if canImport(FBSDKCoreKit)
        guard isLive else { return }
        AppEvents.shared.logEvent(.completedRegistration)
        #endif
    }
}
