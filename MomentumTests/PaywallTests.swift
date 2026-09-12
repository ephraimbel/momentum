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
        #expect(pw.isEntitled(to: .routeReplay) == false)
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

    @Test func clientConversionClaimIsIdempotentAcrossPaywallViews() {
        let pw = PaywallController(isPro: false)
        let productID = pw.offering.annual.id

        #expect(pw.claimPurchaseConversion(for: productID))
        #expect(!pw.claimPurchaseConversion(for: productID))

        // A different store product is a distinct purchase signal; RevenueCat still owns the
        // transaction ledger and decides whether that transition is actually possible.
        #expect(pw.claimPurchaseConversion(for: pw.offering.monthly.id))
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
        #expect(Feature.routeReplay.placement == "route_replay")
        #expect(Feature.fullPlan.placement == "full_plan")
        #expect(Feature.programs.placement == "full_plan")
    }

    @Test func sevenDayTrialIsAnnualOnly() {
        let offering = PaywallOffering.standard
        // Owner call 2026-09-11: the annual offers a seven-day trial; monthly is the
        // low-commitment entry plan and charges the same day, so there is no trial to cancel.
        #expect(offering.annual.trialDays == 7)
        #expect(offering.monthly.trialDays == 0)
        #expect(offering.annualSavingsPercent == 75)   // 75.0% ($29.99 vs 12 × $9.99), rounded to nearest 5%
    }

    /// Monthly-anchored pricing (owner call 2026-09-07, weekly retired): a $9.99 month is the
    /// entry plan and the yearly sits about 75% under its run-rate, sold at its own monthly number
    /// ($2.50/mo). The pair must stay derivable from the two constants — a hand-written badge or
    /// per-month string is how these fall out of step with what the store charges.
    @Test func pricingIsTheMonthlyAnchoredPair() {
        let offering = PaywallOffering.standard
        #expect(offering.monthly.priceText == "$9.99")
        #expect(offering.annual.priceText == "$29.99")
        #expect(offering.monthly.period == .monthly)
        #expect(offering.annual.period == .annual)
        #expect(offering.monthly.id == "momentum_pro_monthly")
        // The yearly's headline: its own per-month price, derived — never typed.
        #expect(offering.annual.perMonthText == "$2.50 / mo")
        // The entry plan never advertises a per-month equivalent — it IS the monthly price.
        #expect(offering.monthly.perMonthText == nil)
    }

    /// The badge follows the numbers, in both directions — the guard that stops a price change
    /// from leaving a stale "SAVE 55%" on screen.
    @Test func savingsBadgeTracksLivePrices() {
        var offering = PaywallOffering.standard
        offering.monthlyPriceValue = 14.99
        offering.annualPriceValue = 89.94             // exactly half the run-rate
        #expect(offering.annualSavingsPercent == 50)
        offering.annualPriceValue = 179.88            // no saving at all
        #expect(offering.annualSavingsPercent == 0)
    }
}
