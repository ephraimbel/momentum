import Foundation
import SwiftData
import UserNotifications

/// The Siri logging core — `LogMealIntent` stays thin and calls this. Runs the SAME local
/// resolution ladder as the Fuel composer's first two rungs (remembered meals → the staples
/// table), saves, and builds the receipt Siri speaks and the notification shows.
///
/// Deliberately does NOT fire the AI estimator: that call is billed and Pro-walled, and every
/// caller routes through the one audited boundary in FuelView. A meal Siri can't resolve locally
/// lands as `pending` with zero attempts spent, and the journal's existing bounded retry tallies
/// it on the next Fuel visit — so a free athlete's gel still logs instantly and costs nothing,
/// and Siri answers in well under a second with no network dependency.
@MainActor
enum SiriMealLogger {

    struct Receipt: Equatable, Sendable {
        let mealID: UUID
        let title: String
        let body: String
        let resolved: Bool
        /// What Siri speaks back.
        let dialog: String
    }

    /// Log dictated text exactly like the composer's local rungs. The meal is saved before
    /// anything else (offline-first, zero lost meals); numbers fill in when a rung hits.
    /// Returns nil only when the WRITE fails — the caller must not claim success then.
    @discardableResult
    static func log(text: String, in context: ModelContext) -> Receipt? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

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
        return receipt(for: meal, resolved: resolved)
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
                           title: "Logged to Fuel",
                           body: "\(display) · \(parts.joined(separator: " · "))",
                           resolved: true,
                           dialog: "Logged — about \(kcal) calories\(carbsSpoken).")
        }
        // Unresolved locally: honest about when the numbers land (the journal's retry, or the
        // athlete's own manual entry — floors, never shame).
        return Receipt(mealID: meal.id,
                       title: "Logged to Fuel",
                       body: "\(display) — totals land next time you open Fuel.",
                       resolved: resolved,
                       dialog: "Logged to Fuel. I'll tally the numbers when you open the app.")
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

    private nonisolated static func deliver(_ receipt: Receipt, to center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = receipt.title
        content.body = receipt.body
        content.sound = .default
        content.categoryIdentifier = NotificationService.mealReceiptCategory
        content.userInfo = ["mealID": receipt.mealID.uuidString]
        center.add(UNNotificationRequest(
            identifier: "momentum.meal.receipt.\(receipt.mealID.uuidString)",
            content: content, trigger: nil))
    }
}
