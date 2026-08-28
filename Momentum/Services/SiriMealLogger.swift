import Foundation
import SwiftData
import UserNotifications

/// The Siri logging core — `LogMealIntent` stays thin and calls this. The full ladder mirrors
/// the Fuel composer: remembered meals → the staples table (free, local, instant), then the AI
/// estimator — but the billed call fires ONLY for entitled installs (`storedEntitlement`, the
/// same boundary FuelView walls). A free athlete's gel logs instantly and costs nothing; a meal
/// nobody could resolve lands `pending` for the journal's bounded retry. The meal is ALWAYS
/// saved first (offline-first, zero lost meals) — estimation only ever adds numbers.
@MainActor
enum SiriMealLogger {

    /// The persisted Pro entitlement, readable without a `PaywallController` (the intent runs in
    /// a bare background launch). Honors BOTH keys: the RevenueCat-owned entitlement, and — in
    /// DEBUG only — the dev unlock, so a dev-unlocked phone gets the same Siri experience as a
    /// subscriber (it didn't, and the gap read as "Siri can't estimate").
    nonisolated static func storedEntitlement(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        if defaults.bool(forKey: PaywallController.devUnlockKey) { return true }
        #endif
        return defaults.bool(forKey: PaywallController.entitlementKey)
    }

    struct Receipt: Equatable, Sendable {
        let mealID: UUID
        let title: String
        let body: String
        let resolved: Bool
        /// What Siri speaks back.
        let dialog: String
    }

    /// A repeated ask within this window for a meal that has NO numbers yet is a RETRY, not a
    /// second meal — "did that work?" re-invocations are how people talk to assistants when
    /// nothing confirmed the first ask. A RESOLVED prior meal never dedupes: Siri already spoke
    /// its numbers back, so a same-text repeat is real intake — a second gel two minutes into an
    /// aid station is exactly this app's audience. Siri-path only: the in-app composer is
    /// deliberate typing and stays un-deduped.
    static let duplicateWindowS: TimeInterval = 120

    /// Log dictated text exactly like the composer's local rungs. The meal is saved before
    /// anything else (offline-first, zero lost meals); numbers fill in when a rung hits.
    /// Returns nil only when the WRITE fails — the caller must not claim success then.
    @discardableResult
    static func log(text: String, in context: ModelContext, now: Date = Date()) -> Receipt? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Idempotency: an identical meal (same canonical key) logged moments ago answers this
        // ask — no duplicate row, no duplicate estimate.
        if let recent = recentDuplicate(of: trimmed, in: context, now: now) {
            return receipt(for: recent, resolved: recent.kcal != nil)
        }

        // Resolved BEFORE the insert so the meal being logged can't be its own candidate
        // (mirrors FuelView.log).
        let remembered = FuelLocalResolver.match(for: trimmed, in: context)

        let meal = Meal()
        meal.text = trimmed
        let resolved: Bool
        if let remembered {
            FuelLocalResolver.copyNumbers(from: remembered, to: meal)
            resolved = true
        } else {
            resolved = FuelLocalResolver.applyStaples(to: meal, text: trimmed)
        }

        context.insert(meal)
        do { try context.save() } catch {
            context.delete(meal)   // never hand back a receipt for a write that didn't land
            return nil
        }
        AppReview.recordMealLogged()   // counted only once the write actually landed
        return receipt(for: meal, resolved: resolved)
    }

    /// The full Siri ladder: local rungs, then — for entitled installs only — the AI estimator,
    /// awaited so Siri can SPEAK the real numbers ("a Fairlife 40g protein shake" reads perfectly).
    /// Free installs never reach the billed call — same boundary as FuelView's walls. Attempt
    /// accounting mirrors FuelView.estimate exactly: count at fire, refund on `.unavailable`
    /// (never sent ⇒ never owed), stand on `.declined`.
    static func logAndEstimate(text: String, in context: ModelContext,
                               entitled: Bool = SiriMealLogger.storedEntitlement(),
                               estimate: ((String) async -> FuelEstimator.Outcome)? = nil) async -> Receipt? {
        guard let base = log(text: text, in: context) else { return nil }
        guard !base.resolved, entitled else { return base }

        let id = base.mealID
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.id == id })
        guard let meal = (try? context.fetch(descriptor))?.first else { return base }

        // The journal's bounded-retry cap governs here too (a deduped retry of a meal the model
        // has already declined three times must rest, not bill forever). 3 mirrors
        // FuelView.maxEstimateAttempts.
        guard meal.needsEstimate(maxAttempts: 3) else { return base }

        // One bill per meal across ALL paths — if the Fuel page (or a racing invocation) is
        // already estimating this meal, its result lands the same way; don't pay twice.
        guard let gateToken = EstimateGate.begin(id) else { return base }
        defer { EstimateGate.end(id, token: gateToken) }

        meal.estimateAttempts += 1
        try? context.save()
        let run = estimate ?? { text in
            await FuelEstimator().estimate(text: text, sessionLabel: nil, durationS: nil)
        }
        let outcome = await run(meal.text)
        guard !meal.isDeleted, meal.modelContext != nil else { return base }
        switch outcome {
        case .estimated(let e):
            FuelEstimator.apply(e, to: meal)
            meal.estimateAttempts = 0   // it resolved; nothing owed
            try? context.save()
            return receipt(for: meal, resolved: true)
        case .unavailable:
            meal.estimateAttempts = max(0, meal.estimateAttempts - 1)
            try? context.save()
        case .declined:
            break
        }
        return receipt(for: meal, resolved: false)
    }

    /// The meal that makes a fresh ask a duplicate: same canonical text key, eaten inside the
    /// window, and still UNRESOLVED (see `duplicateWindowS` — a resolved prior meal was
    /// confirmed aloud, so a repeat is real intake). Junk text (unmatchable keys) never
    /// dedupes — two mumbles are two meals.
    private static func recentDuplicate(of text: String, in context: ModelContext, now: Date) -> Meal? {
        let key = MealTextKey.normalized(text)
        guard MealTextKey.isMatchable(key) else { return nil }
        let cutoff = now.addingTimeInterval(-duplicateWindowS)
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.eatenAt >= cutoff },
                                               sortBy: [SortDescriptor(\.eatenAt, order: .reverse)])
        guard let candidate = (try? context.fetch(descriptor))?
            .first(where: { MealTextKey.normalized($0.text) == key }),
              candidate.kcal == nil else { return nil }
        return candidate
    }

    /// Remove a meal by id — the notification receipt's Undo. Safe against double-taps and
    /// already-deleted meals (both no-op).
    static func undoMeal(id: UUID, in context: ModelContext) {
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.id == id })
        guard let meal = (try? context.fetch(descriptor))?.first else { return }
        context.delete(meal)
        try? context.save()
    }

    // MARK: Receipt

    /// The receipt in both voices: the notification line ("Energy gel · ≈100 kcal · 25g carbs")
    /// and what Siri says out loud. Pure — unit-tested.
    static func receipt(for meal: Meal, resolved: Bool) -> Receipt {
        let display = meal.text.isEmpty ? "Meal" : meal.text
        if resolved, let kcal = meal.kcal {
            var parts = ["≈\(kcal) kcal"]
            if let carbs = meal.carbsG { parts.append("\(carbs)g carbs") }
            if let protein = meal.proteinG, protein > 0 { parts.append("\(protein)g protein") }
            if let sodium = meal.sodiumMg, sodium > 0 { parts.append("\(sodium)mg sodium") }
            let carbsSpoken = meal.carbsG.map { ", \($0) grams of carbs" } ?? ""
            return Receipt(mealID: meal.id,
                           title: "Logged to Momentum",
                           body: "\(display) · \(parts.joined(separator: " · "))",
                           resolved: true,
                           dialog: "Logged — about \(kcal) calories\(carbsSpoken).")
        }
        // Unresolved: the notification IS the confirmation — it echoes the athlete's own words
        // and never points them at the app ("open Momentum to verify" is homework, not a
        // receipt). Numbers join quietly once a rung lands them; the journal shows the pending
        // state honestly in the meantime.
        return Receipt(mealID: meal.id,
                       title: "Logged to Momentum",
                       body: display,
                       resolved: resolved,
                       dialog: "Logged to Momentum.")
    }

    /// Post the receipt notification (with Undo). If the athlete never answered the notification
    /// prompt, ask PROVISIONALLY — iOS grants that silently (no dialog mid-Siri), and the receipt
    /// lands quietly in Notification Center. Explicitly denied stays denied — Siri's spoken
    /// dialog is the receipt of record either way.
    static func postReceipt(_ receipt: Receipt) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in
                    deliver(receipt, to: center)
                }
            } else {
                deliver(receipt, to: center)
            }
        }
    }

    /// Set once a receipt has been posted — the app's next open promotes provisional (quiet)
    /// notification delivery to full banners via the real system prompt (see
    /// `NotificationService.promoteReceiptAuthorizationIfNeeded`).
    nonisolated static let receiptPostedKey = "com.momentum.siri.receiptPosted"

    private nonisolated static func deliver(_ receipt: Receipt, to center: UNUserNotificationCenter) {
        UserDefaults.standard.set(true, forKey: receiptPostedKey)
        let content = UNMutableNotificationContent()
        content.title = receipt.title
        content.body = receipt.body
        content.sound = .default
        content.categoryIdentifier = NotificationService.mealReceiptCategory
        // One thread: a day of voice-logged meals stacks as a tidy group, not a scattered pile.
        content.threadIdentifier = "momentum.meal.receipts"
        content.userInfo = ["mealID": receipt.mealID.uuidString]
        center.add(UNNotificationRequest(
            identifier: "momentum.meal.receipt.\(receipt.mealID.uuidString)",
            content: content, trigger: nil))
    }
}
