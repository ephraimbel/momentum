import Testing
import StoreKit
@testable import Momentum

/// The SKAdNetwork conversion-value schema is a WIRE FORMAT shared with the ad network's own
/// mapping (TikTok Events Manager → SKAN conversion values). These tests pin the properties that
/// silently corrupt every historical postback if they drift.
@MainActor
struct SKANConversionTests {

    /// Apple discards a fine value lower than the one already set in the window, so the funnel
    /// must ascend. If a step is ever inserted in the middle, this fails first.
    @Test func stepsAscendByFunnelDepth() {
        let ordered = SKANConversion.Step.allCases.sorted()
        #expect(ordered == [.install, .planBuilt, .paywallSeen, .accountCreated,
                            .trialStarted, .subscribed])
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            #expect(a.rawValue < b.rawValue, "\(a) must sort below \(b)")
        }
    }

    /// The numbering IS the wire format — renumbering silently re-reads every past postback as a
    /// different step. Change these only alongside the network-side schema.
    @Test func rawValuesArePinned() {
        #expect(SKANConversion.Step.install.rawValue == 0)
        #expect(SKANConversion.Step.planBuilt.rawValue == 1)
        #expect(SKANConversion.Step.paywallSeen.rawValue == 2)
        #expect(SKANConversion.Step.accountCreated.rawValue == 3)
        #expect(SKANConversion.Step.trialStarted.rawValue == 4)
        #expect(SKANConversion.Step.subscribed.rawValue == 5)
    }

    /// Six bits is the whole budget Apple gives us.
    @Test func everyStepFitsApplesSixBitFineValue() {
        for step in SKANConversion.Step.allCases {
            #expect((0...63).contains(step.rawValue))
        }
    }

    /// Under Apple's crowd-anonymity threshold the network sees ONLY this, so the coarse buckets
    /// have to carry the funnel's shape on their own: pre-intent, intent, money.
    @Test func coarseBucketsRiseWithTheFunnel() {
        #expect(SKANConversion.Step.install.coarse == .low)
        #expect(SKANConversion.Step.planBuilt.coarse == .low)
        #expect(SKANConversion.Step.paywallSeen.coarse == .medium)
        #expect(SKANConversion.Step.accountCreated.coarse == .medium)
        #expect(SKANConversion.Step.trialStarted.coarse == .high)
        #expect(SKANConversion.Step.subscribed.coarse == .high)
    }

    /// Locking ends the measurement window early, so only the terminal step may do it — locking
    /// sooner would throw away every deeper conversion that follows.
    @Test func onlyTheTerminalStepLocksTheWindow() {
        for step in SKANConversion.Step.allCases {
            #expect(step.locksWindow == (step == .subscribed),
                    "\(step) must not close the attribution window")
        }
    }
}
