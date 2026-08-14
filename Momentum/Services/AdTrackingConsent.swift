import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(FBSDKCoreKit)
import FBSDKCoreKit
#endif

/// App Tracking Transparency — the consent gate in front of Meta's app events.
///
/// Added 2026-08-13 (owner call). Until then the app deliberately shipped with NO ad-network
/// events at all, because sending them is "tracking" by Apple's definition (a third-party SDK
/// combining this app's data with another developer's data to measure advertising) and declaring
/// tracking obligates this prompt. `TikTokAdsService` is still dark for exactly that reason; Meta
/// is the one network we opted in for, so the prompt exists to cover it.
///
/// Three rules this type exists to enforce:
///  - **Ask once, and only when the athlete can understand why.** The prompt fires after onboarding
///    is behind them, never at cold launch on a first run. iOS itself only shows the dialog once
///    per install, but `requestOnce` also keeps us from re-entering while it is on screen.
///  - **Ask only while active.** `ATTrackingManager` silently returns `.denied` if the app is not
///    foreground-active, which would burn the one prompt the install ever gets.
///  - **Denial is a real answer, and it costs nothing.** Meta's SDK keeps working without the IDFA
///    (SKAdNetwork + Aggregated Event Measurement carry attribution), so a "no" degrades targeting
///    precision rather than breaking the funnel. Nothing in the app is gated on the answer.
@MainActor
enum AdTrackingConsent {

    /// Guards against a second `request` while the system dialog is already up.
    private static var isRequesting = false

    /// True once the athlete has answered — in either direction.
    static var hasBeenAsked: Bool {
        #if canImport(AppTrackingTransparency)
        return ATTrackingManager.trackingAuthorizationStatus != .notDetermined
        #else
        return true
        #endif
    }

    /// Ask for tracking permission if iOS has not already recorded an answer.
    ///
    /// Safe to call on every launch: it no-ops once a decision exists. Hermetic runs (demo seeds
    /// and UI tests) skip it so an unexpected system alert can never eat a test's taps.
    static func requestOnce() {
        #if canImport(AppTrackingTransparency)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--seed-demo") || args.contains("--debug-pro") || args.contains("--debug-free")
            || args.contains("--ui-test-route") { return }
        #endif
        guard !isRequesting, ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
            // Already answered on a previous launch — make sure the SDK matches that answer.
            applyToAdSDKs()
            return
        }
        isRequesting = true
        ATTrackingManager.requestTrackingAuthorization { _ in
            Task { @MainActor in
                isRequesting = false
                applyToAdSDKs()
            }
        }
        #endif
    }

    /// Mirror the athlete's answer into Meta's SDK.
    ///
    /// `FacebookAdvertiserIDCollectionEnabled` is true in Info.plist so the SDK *may* read the
    /// IDFA, but "may" is not "should": we set the flag explicitly from the ATT status so a denial
    /// is honored even if Apple's own gate were ever loosened. Event logging itself is unaffected
    /// either way — only the identifier is.
    private static func applyToAdSDKs() {
        #if canImport(FBSDKCoreKit) && canImport(AppTrackingTransparency)
        let authorized = ATTrackingManager.trackingAuthorizationStatus == .authorized
        Settings.shared.isAdvertiserIDCollectionEnabled = authorized
        Settings.shared.isAdvertiserTrackingEnabled = authorized
        #endif
    }
}
