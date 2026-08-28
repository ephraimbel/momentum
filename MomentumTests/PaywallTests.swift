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

    @Test func noPlanCarriesATrial() {
        let offering = PaywallOffering.standard
        // Trial retired entirely (owner call 2026-08-20, supersedes the 07-30 annual-only nudge):
        // the soft paywall is the trial, and the yearly sells on the savings badge. The store's
        // intro offers were deleted in every territory; the placeholder must agree so DEBUG and
        // production tell the same story.
        #expect(offering.annual.trialDays == 0)
        #expect(offering.weekly.trialDays == 0)
        #expect(offering.annualSavingsPercent == 90)   // 90.37% ($29.99 vs 52 × $5.99), rounded to nearest 5%
    }

    /// Weekly-anchored pricing (owner call 2026-08-28, yearly cut to $29.99 for conversion): a
    /// $5.99 week is the entry plan and the yearly sits 90% under its run-rate, sold at its own
    /// weekly number ($0.58/wk). The pair must stay derivable from the two constants — a hand-written
    /// badge or per-week string is how these fall out of step with what the store charges.
    @Test func pricingIsTheWeeklyAnchoredPair() {
        let offering = PaywallOffering.standard
        #expect(offering.weekly.priceText == "$5.99")
        #expect(offering.annual.priceText == "$29.99")
        #expect(offering.weekly.period == .weekly)
        #expect(offering.annual.period == .annual)
        // The yearly's headline: its own per-week price, derived — never typed.
        #expect(offering.annual.perWeekText == "$0.58 / wk")
        // The entry plan never advertises a per-week equivalent — it IS the weekly price.
        #expect(offering.weekly.perWeekText == nil)
    }

    /// The badge follows the numbers, in both directions — the guard that stops a price change
    /// from leaving a stale "SAVE 75%" on screen.
    @Test func savingsBadgeTracksLivePrices() {
        var offering = PaywallOffering.standard
        offering.weeklyPriceValue = 5.99
        offering.annualPriceValue = 155.74            // exactly half the run-rate
        #expect(offering.annualSavingsPercent == 50)
        offering.annualPriceValue = 311.48            // no saving at all
        #expect(offering.annualSavingsPercent == 0)
    }
}
