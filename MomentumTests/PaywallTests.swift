import Testing
@testable import Momentum

/// Pro gating is the single source of truth (PRD §10): free by default, Pro unlocks exactly the
/// `Feature` set, purchase/restore flip entitlement, and locked-only presentation.
@MainActor
struct PaywallTests {

    @Test func freeByDefaultGatesProFeatures() {
        let pw = PaywallController(isPro: false)
        #expect(pw.isPro == false)
        #expect(pw.isEntitled(to: .aiRead) == false)
        #expect(pw.isEntitled(to: .advancedAnalytics) == false)
    }

    @Test func proUnlocksEveryFeature() {
        let pw = PaywallController(isPro: true)
        for feature in Feature.allCases {
            #expect(pw.isEntitled(to: feature), "Pro should unlock \(feature)")
        }
    }

    @Test func purchaseGrantsEntitlement() async {
        let pw = PaywallController(isPro: false)
        let outcome = await pw.purchase(pw.offering.annual)
        #expect(outcome == .purchased)
        #expect(pw.isPro)
        #expect(pw.isEntitled(to: .fullPlan))
        pw.resetForTesting()
    }

    /// A purchase attempt reports WHY it ended. These three cases used to collapse into one `false`,
    /// so the paywall couldn't tell a cancelled sheet from a store failure and stayed silent for
    /// both — a dead Buy button for anyone actually trying to pay.
    @Test func purchaseOutcomeDistinguishesCancelFromFailure() {
        #expect(PurchaseOutcome.purchased != PurchaseOutcome.cancelled)
        #expect(PurchaseOutcome.cancelled != PurchaseOutcome.failed("boom"))
        #expect(PurchaseOutcome.failed("boom") == PurchaseOutcome.failed("boom"))
        // A failure always carries something worth showing — an empty alert is the old bug again.
        if case .failed(let message) = PurchaseOutcome.failed("Check your connection.") {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected a failure message")
        }
    }

    /// Placeholder prices are US dollars. Until the store's offering lands the paywall must not
    /// present them as fact — `pricingIsLive` is what the view keys the price, the savings line,
    /// the CTA, and the renewal fine print off.
    @Test func pricingIsNotLiveUntilTheStoreAnswers() {
        let pw = PaywallController(isPro: false)
        #expect(pw.pricingIsLive == false)
        // The placeholder offering still populates so the layout has something to size against.
        #expect(!pw.offering.annual.priceText.isEmpty)
    }

    @Test func presentsOnlyWhenLocked() {
        let locked = PaywallController(isPro: false)
        locked.present(for: .aiRead)
        #expect(locked.presentedFeature == .aiRead)

        let entitled = PaywallController(isPro: true)
        entitled.present(for: .aiRead)
        #expect(entitled.presentedFeature == nil)   // already Pro — never nag
    }

    @Test func featuresMapToSuperwallPlacements() {
        #expect(Feature.aiRead.placement == "ai_read")
        #expect(Feature.advancedAnalytics.placement == "analytics_locked")
        #expect(Feature.fullHistory.placement == "history_locked")
        #expect(Feature.fullPlan.placement == "full_plan")
        #expect(Feature.programs.placement == "full_plan")
    }

    @Test func annualOfferingCarriesTheTrial() {
        let offering = PaywallOffering.standard
        #expect(offering.annual.trialDays == 7)
        #expect(offering.monthly.trialDays == 0)
        #expect(offering.annualSavingsPercent == 40)   // 38.85% ($109.99 vs 12 × $14.99), rounded to nearest 5%
    }

    /// Monthly is priced UNDER Runna (~$17.99/mo) to win the price-comparison shopper (2026-07-14).
    @Test func monthlyPriceUndercutsRunna() {
        let offering = PaywallOffering.standard
        #expect(offering.monthly.priceText == "$14.99")
        #expect(offering.annual.priceText == "$109.99")
        #expect(offering.monthly.period == .monthly)
    }
}
