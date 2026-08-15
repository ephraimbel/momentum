import Foundation
import StoreKit

/// SKAdNetwork conversion values — ad measurement WITHOUT tracking.
///
/// This is Apple's own attribution framework, not a third-party SDK. The postback travels from
/// Apple to the ad network, carries no device or user identifier, and therefore needs **no App
/// Tracking Transparency prompt and no App Privacy disclosure** — which is exactly why it can
/// ship while `TikTokAdsService`/`MetaAdsService` stay dark (see the note on TikTokAdsService for
/// why their event reporting is "tracking" and this is not).
///
/// What it buys: the ad network learns "a campaign produced an install that later reached step
/// N", so it can optimise toward trials and subscriptions instead of the cheapest possible
/// install. Nothing about *which* person is ever transmitted.
///
/// The three rules of SKAdNetwork that shape this file:
///  1. **Values only ascend.** Apple discards a fine value lower than the one already set inside
///     the attribution window, so `Step` is ordered by funnel depth and `record` refuses to walk
///     backwards. Steps genuinely skipped (a subscriber never reports `accountCreated`, because
///     the money event outranks it) are correct, not lost data.
///  2. **Six bits, nothing more.** The fine value is 0…63. When install volume sits under
///     Apple's crowd-anonymity threshold the network receives only the *coarse* value, so every
///     step declares one.
///  3. **The first call opens the window.** Posting a value on first launch is what starts
///     attribution on modern iOS; `registerAppForAdNetworkAttribution()` is deprecated.
///
/// The network side must mirror `Step`'s numbering in its conversion-value schema (TikTok Events
/// Manager → the app → SKAN conversion values). **If you renumber `Step`, update that schema in
/// the same change or every historical postback is misread.**
@MainActor
enum SKANConversion {

    /// The funnel, ordered by business value. The numbering IS the wire format (see the schema
    /// note above), so append new steps rather than renumbering existing ones.
    ///
    /// Ordering note: the paywall is shown BEFORE the account beat in onboarding, and a purchase
    /// happens on that paywall, so a subscriber legitimately never reports `accountCreated`.
    enum Step: Int, Comparable, CaseIterable, Sendable {
        /// First launch. Opens the attribution window.
        case install = 0
        /// Onboarding finished and a real training plan exists — the activation moment.
        case planBuilt = 1
        /// Reached the subscription page.
        case paywallSeen = 2
        /// A real (non-guest) account landed.
        case accountCreated = 3
        /// Free trial started.
        case trialStarted = 4
        /// Paid subscription landed. The deepest step there is.
        case subscribed = 5

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        /// What the ad network receives when Apple hides the fine value for privacy.
        var coarse: SKAdNetwork.CoarseConversionValue {
            switch self {
            case .install, .planBuilt:          .low
            case .paywallSeen, .accountCreated: .medium
            case .trialStarted, .subscribed:    .high
            }
        }

        /// Money landed and nothing deeper can follow, so the window may close early — the ad
        /// network gets its postback sooner, which is what makes bidding responsive.
        var locksWindow: Bool { self == .subscribed }
    }

    /// Highest step already reported. Persisted so relaunches, restores and repeat purchases
    /// never re-post the same value or try to walk it backwards. `-1` = nothing reported yet,
    /// which is why this reads `object(forKey:)` rather than `integer(forKey:)` (the latter
    /// returns 0, indistinguishable from a recorded `.install`).
    private static var highestRaw: Int {
        get { UserDefaults.standard.object(forKey: key) as? Int ?? -1 }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    private static let key = "com.momentum.skan.highestStep"

    /// The deepest step reported so far, for diagnostics.
    static var reached: Step? { Step(rawValue: highestRaw) }

    /// Open the attribution window (call once from `MomentumApp.init`).
    static func registerInstall() { record(.install) }

    /// Report a funnel step. Safe to call repeatedly, in any order, from anywhere: only a
    /// genuinely deeper step produces a postback update.
    static func record(_ step: Step) {
        #if DEBUG
        // Same hermeticity contract as billing and the ad SDKs: a demo/UI-test run must not
        // write attribution state or post conversion values.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--seed-demo") || args.contains("--debug-pro") || args.contains("--debug-free")
            || args.contains("--ui-test-route") { return }
        #endif
        guard step.rawValue > highestRaw else { return }
        highestRaw = step.rawValue
        Task {
            // A failed postback costs an advertiser one data point; it costs the athlete nothing,
            // so it is swallowed rather than surfaced. Simulator and StoreKit-less environments
            // throw here routinely.
            try? await SKAdNetwork.updatePostbackConversionValue(step.rawValue,
                                                                 coarseValue: step.coarse,
                                                                 lockWindow: step.locksWindow)
        }
    }
}
