import Foundation
import Testing
import SwiftData
@testable import Momentum

/// The Siri logging core: same local ladder as the composer, honest receipts, safe undo.
@MainActor
struct SiriMealLoggerTests {

    /// The controller must outlive the context — returning `mainContext` alone lets the container
    /// deallocate under it, and the next fetch traps inside SwiftData.
    private func fresh() -> (keep: PersistenceController, context: ModelContext) {
        let pc = PersistenceController.inMemory()
        return (pc, pc.container.mainContext)
    }

    @Test func stapleResolvesWithFullReceipt() throws {
        let (pc, context) = fresh(); _ = pc
        let receipt = try #require(SiriMealLogger.log(text: "energy gel and a banana", in: context))

        // The meal is saved and carries staple numbers (gel + banana are both curated staples).
        let meals = try context.fetch(FetchDescriptor<Meal>())
        #expect(meals.count == 1)
        let meal = try #require(meals.first)
        #expect(meal.text == "energy gel and a banana")
        #expect(receipt.resolved)
        #expect(meal.kcal != nil)
        #expect((meal.carbsG ?? 0) > 0)   // a gel is carbs by definition
        // No estimator budget spent — the AI rung is deliberately not fired from Siri.
        #expect(meal.estimateAttempts == 0)

        // Receipt speaks the numbers.
        #expect(receipt.body.contains("kcal"))
        #expect(receipt.dialog.contains("calories"))
    }

    @Test func unknownFoodLogsPendingWithHonestReceipt() throws {
        let (pc, context) = fresh(); _ = pc
        let receipt = try #require(SiriMealLogger.log(text: "grandma's mystery casserole", in: context))

        let meal = try #require(try context.fetch(FetchDescriptor<Meal>()).first)
        #expect(meal.source == "pending")
        #expect(meal.kcal == nil)
        #expect(!receipt.resolved)
        // The notification IS the confirmation: it echoes the athlete's words, and never
        // points them at the app ("open Momentum to verify" is homework, not a receipt).
        #expect(receipt.body == "grandma's mystery casserole")
        #expect(!receipt.body.lowercased().contains("open"))
        #expect(!receipt.dialog.contains("calories"))
        // Pending with zero attempts spent: the journal's bounded retry owns the AI rung.
        #expect(meal.estimateAttempts == 0)
    }

    @Test func rememberedMealNumbersAreCopied() throws {
        let (pc, context) = fresh(); _ = pc
        // The athlete's own hand-corrected shake, from history.
        let past = Meal()
        past.text = "my recovery shake"
        past.kcal = 320
        past.carbsG = 40
        past.proteinG = 30
        past.source = "manual"
        context.insert(past)
        try context.save()

        let receipt = try #require(SiriMealLogger.log(text: "my recovery shake", in: context))
        #expect(receipt.resolved)
        let logged = try context.fetch(FetchDescriptor<Meal>()).first { $0.id == receipt.mealID }
        #expect(logged?.kcal == 320)
        #expect(logged?.proteinG == 30)
        #expect(receipt.dialog.contains("320"))
    }

    @Test func emptyTextRefusesToLog() throws {
        let (pc, context) = fresh(); _ = pc
        #expect(SiriMealLogger.log(text: "   ", in: context) == nil)
        #expect(try context.fetch(FetchDescriptor<Meal>()).isEmpty)
    }

    @Test func freeInstallNeverFiresTheEstimatorAndSaysSo() async throws {
        let (pc, context) = fresh(); _ = pc
        let receipt = try #require(await SiriMealLogger.logAndEstimate(
            text: "fairlife 40g protein shake", in: context, entitled: false,
            estimate: { _ in
                Issue.record("the billed estimator must never fire for a free install")
                return .declined
            }))
        #expect(!receipt.resolved)
        #expect(receipt.body == "fairlife 40g protein shake")   // the echo IS the receipt
        let meal = try #require(try context.fetch(FetchDescriptor<Meal>()).first)
        #expect(meal.estimateAttempts == 0)
    }

    @Test func entitledOfflineRefundsTheAttempt() async throws {
        let (pc, context) = fresh(); _ = pc
        let receipt = try #require(await SiriMealLogger.logAndEstimate(
            text: "fairlife 40g protein shake", in: context, entitled: true,
            estimate: { _ in .unavailable }))
        #expect(!receipt.resolved)
        #expect(receipt.body == "fairlife 40g protein shake")
        let meal = try #require(try context.fetch(FetchDescriptor<Meal>()).first)
        // Never sent ⇒ never owed: still due when the journal's retry has a network.
        #expect(meal.estimateAttempts == 0)
    }

    @Test func entitledDeclinedSpendsTheAttempt() async throws {
        let (pc, context) = fresh(); _ = pc
        _ = try #require(await SiriMealLogger.logAndEstimate(
            text: "fairlife 40g protein shake", in: context, entitled: true,
            estimate: { _ in .declined }))
        let meal = try #require(try context.fetch(FetchDescriptor<Meal>()).first)
        // The model answered and still had no numbers — the attempt stands (bounded retry).
        #expect(meal.estimateAttempts == 1)
    }

    @Test func localResolveShortCircuitsTheEstimator() async throws {
        let (pc, context) = fresh(); _ = pc
        let receipt = try #require(await SiriMealLogger.logAndEstimate(
            text: "energy gel", in: context, entitled: true,
            estimate: { _ in
                Issue.record("a staple resolve must never also bill an estimate")
                return .declined
            }))
        #expect(receipt.resolved)
    }

    @Test func repeatedAskWithinWindowIsARetryNotASecondMeal() throws {
        let (pc, context) = fresh(); _ = pc
        let t0 = Date()
        // Unresolved meal (no numbers spoken back) → the identical ask 30s later is a
        // "did that work?" retry and answers with the SAME meal.
        let first = try #require(SiriMealLogger.log(text: "grandma's mystery casserole",
                                                    in: context, now: t0))
        let retry = try #require(SiriMealLogger.log(text: "Grandma's Mystery Casserole",
                                                    in: context, now: t0.addingTimeInterval(30)))
        #expect(retry.mealID == first.mealID)
        #expect(try context.fetch(FetchDescriptor<Meal>()).count == 1)
        // Past the window it's a real second serving.
        let later = try #require(SiriMealLogger.log(text: "grandma's mystery casserole",
                                                    in: context, now: t0.addingTimeInterval(200)))
        #expect(later.mealID != first.mealID)
    }

    @Test func resolvedMealRepeatIsRealIntakeNotARetry() throws {
        let (pc, context) = fresh(); _ = pc
        let t0 = Date()
        // A staple resolves instantly and Siri SPOKE its numbers — a second identical ask two
        // minutes into an aid station is a second gel, and it must count.
        let first = try #require(SiriMealLogger.log(text: "energy gel", in: context, now: t0))
        #expect(first.resolved)
        let second = try #require(SiriMealLogger.log(text: "energy gel", in: context,
                                                     now: t0.addingTimeInterval(60)))
        #expect(second.mealID != first.mealID)
        #expect(try context.fetch(FetchDescriptor<Meal>()).count == 2)
    }

    @Test func estimateGateBlocksConcurrentDoubleBilling() async throws {
        let (pc, context) = fresh(); _ = pc
        // First ask parks mid-estimate; the retry arrives while it's in flight.
        let firstStarted = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let slowFirst = Task { @MainActor in
            await SiriMealLogger.logAndEstimate(
                text: "grandma's mystery casserole", in: context, entitled: true,
                estimate: { _ in
                    firstStarted.continuation.yield()
                    for await _ in release.stream { break }
                    return .declined
                })
        }
        for await _ in firstStarted.stream { break }   // first estimate is now in flight

        // The deduped retry maps to the SAME meal — the gate must refuse a second billed call.
        let retry = try #require(await SiriMealLogger.logAndEstimate(
            text: "grandma's mystery casserole", in: context, entitled: true,
            estimate: { _ in
                Issue.record("second concurrent estimate for the same meal — double billing")
                return .declined
            }))
        #expect(!retry.resolved)

        release.continuation.yield()
        _ = await slowFirst.value
        // The gate released after completion — a later retry may estimate again.
        let meal = try #require(try context.fetch(FetchDescriptor<Meal>()).first)
        #expect(EstimateGate.isEstimating(meal.id) == false)
    }

    @Test func estimateGateTokenSemantics() throws {
        let id = UUID()
        let t1 = try #require(EstimateGate.begin(id))
        #expect(EstimateGate.begin(id) == nil)          // held — a second claim is refused
        let t2 = EstimateGate.take(id)                  // owner restart force-claims
        EstimateGate.end(id, token: t1)                 // stale owner's release is a no-op
        #expect(EstimateGate.isEstimating(id))
        EstimateGate.end(id, token: t2)
        #expect(!EstimateGate.isEstimating(id))
    }

    @Test func dedupedRetryOfARestingMealNeverRebills() async throws {
        let (pc, context) = fresh(); _ = pc
        // A pending meal the model has already declined three times — resting on its words.
        let first = try #require(await SiriMealLogger.logAndEstimate(
            text: "grandma's mystery casserole", in: context, entitled: true,
            estimate: { _ in .declined }))
        let meal = try #require(try context.fetch(FetchDescriptor<Meal>()).first)
        meal.estimateAttempts = 3
        try context.save()

        let retry = try #require(await SiriMealLogger.logAndEstimate(
            text: "grandma's mystery casserole", in: context, entitled: true,
            estimate: { _ in
                Issue.record("a maxed-out meal must rest, not bill a fourth attempt")
                return .declined
            }))
        #expect(retry.mealID == first.mealID)
        #expect(meal.estimateAttempts == 3)
    }

    @Test func storedEntitlementHonorsBothKeys() throws {
        // Suite-scoped defaults — never touch the test host's real entitlement state.
        let suite = "siri-entitlement-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!SiriMealLogger.storedEntitlement(defaults: defaults))
        // A real (RevenueCat-owned) entitlement unlocks the estimator…
        defaults.set(true, forKey: PaywallController.entitlementKey)
        #expect(SiriMealLogger.storedEntitlement(defaults: defaults))
        // …and so does the DEBUG dev unlock alone — a dev-unlocked phone must get the same
        // Siri experience as a subscriber (this exact gap shipped as "Siri can't estimate").
        defaults.set(false, forKey: PaywallController.entitlementKey)
        defaults.set(true, forKey: PaywallController.devUnlockKey)
        #expect(SiriMealLogger.storedEntitlement(defaults: defaults))
    }

    @Test func undoRemovesTheMealAndIsIdempotent() throws {
        let (pc, context) = fresh(); _ = pc
        let receipt = try #require(SiriMealLogger.log(text: "energy gel", in: context))
        #expect(try context.fetch(FetchDescriptor<Meal>()).count == 1)

        SiriMealLogger.undoMeal(id: receipt.mealID, in: context)
        #expect(try context.fetch(FetchDescriptor<Meal>()).isEmpty)

        // A second Undo (double-tap, stale notification) is a quiet no-op.
        SiriMealLogger.undoMeal(id: receipt.mealID, in: context)
        #expect(try context.fetch(FetchDescriptor<Meal>()).isEmpty)
    }
}
