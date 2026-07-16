import Foundation
import SwiftData

/// One logged meal, snack, or drink — the FUEL pillar (decision 2026-07-16, extends ENDURANCE-FOCUS
/// §11 from guidance to tracking). Deliberately athlete-framed: the numbers exist to answer "am I
/// fueled for the work?", never to run a diet ledger. Energy is a FLOOR (fund the training), carbs
/// are the readiness signal, protein the recovery signal, sodium the endurance electrolyte. No
/// weight-loss framing anywhere, ever.
///
/// A meal saves instantly offline — one sentence and/or a photo. The `meal-estimate` Edge Function
/// fills the numbers when reachable (`source == "ai"`); the athlete can always set or correct them
/// (`source == "manual"`, which a later estimate never overwrites); until either happens the meal
/// sits honestly `pending` and the day's totals simply exclude it.
@Model
final class Meal {
    var id: UUID = UUID()
    /// When it was eaten (defaults to logging time; editable so a forgotten lunch lands right).
    var eatenAt: Date = Date()
    /// The athlete's own words — "chicken rice bowl", "2 gels + half a banana", "big pasta dinner".
    var text: String = ""
    /// Optional plate snap, downscaled like workout photos before persisting.
    @Attribute(.externalStorage) var photoData: Data?

    // Estimated (AI) or entered (manual) nutrition. nil = unknown/pending — never treated as zero
    // in a way that shames; totals just note the gap. All SI-adjacent units: g, mg, ml, kcal.
    var kcal: Int?
    var carbsG: Int?
    var proteinG: Int?
    var fatG: Int?
    var sodiumMg: Int?
    var fluidsMl: Int?

    /// The itemized breakdown ("2 eggs · toast · coffee"), JSON-encoded `[MealItem]` — the same
    /// blob pattern as `structuredRepsData`. Totals on the meal are ALWAYS Σ items when items
    /// exist (kept in scalar fields so `FuelReadiness` and queries never decode JSON).
    var itemsData: Data?

    /// "ai" | "manual" | "pending" — provenance of the numbers. Manual always wins.
    var source: String = "pending"
    /// One coach-toned line from the estimator ("Solid pre-long-run fuel."). Display only.
    var note: String?
    /// Estimator confidence 0–1 (surfaced as a quiet "≈" — every number here is approximate).
    var confidence: Double?

    init() {}
}

/// One food inside a meal ("Eggs ×2", "Toast, 1 slice") — the Amy-style breakdown. Codable blob on
/// `Meal.itemsData` (never a @Model: display + portion-editing only; the engine reads meal totals).
/// The nutrition numbers are for the CURRENT `qty`, so per-unit = value / qty and portion changes
/// scale linearly from there.
struct MealItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var qty: Double
    var unit: String
    var kcal: Int
    var carbsG: Int
    var proteinG: Int
    var fatG: Int
    var sodiumMg: Int
    var fluidsMl: Int

    /// This item rescaled to a new quantity — linear from per-unit values, rounded (everything ≈).
    func scaled(to newQty: Double) -> MealItem {
        guard qty > 0, newQty != qty else { var c = self; c.qty = max(0.5, newQty); return c }
        let f = newQty / qty
        var c = self
        c.qty = newQty
        c.kcal = Int((Double(kcal) * f).rounded())
        c.carbsG = Int((Double(carbsG) * f).rounded())
        c.proteinG = Int((Double(proteinG) * f).rounded())
        c.fatG = Int((Double(fatG) * f).rounded())
        c.sodiumMg = Int((Double(sodiumMg) * f).rounded())
        c.fluidsMl = Int((Double(fluidsMl) * f).rounded())
        return c
    }

    /// "2" / "1.5" — quantity with whole numbers kept whole.
    var qtyText: String {
        qty == qty.rounded() ? String(Int(qty)) : String(format: "%.1f", qty)
    }

    /// "2 eggs" / "1.5 slices" / "1 cup" — the stepper's portion label. Units pluralize naturally;
    /// abbreviations (oz, ml) never do.
    var portionLabel: String {
        let plural = qty != 1 && !unit.hasSuffix("s") && unit.count > 2 ? "s" : ""
        return "\(qtyText) \(unit)\(plural)"
    }
}

extension Meal {
    var items: [MealItem] {
        get { itemsData.flatMap { try? JSONDecoder().decode([MealItem].self, from: $0) } ?? [] }
        set {
            itemsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
            applyTotals(from: newValue)
        }
    }

    /// Totals are ALWAYS Σ items when items exist — one source of truth for the engine.
    func applyTotals(from items: [MealItem]) {
        guard !items.isEmpty else { return }
        kcal = items.map(\.kcal).reduce(0, +)
        carbsG = items.map(\.carbsG).reduce(0, +)
        proteinG = items.map(\.proteinG).reduce(0, +)
        fatG = items.map(\.fatG).reduce(0, +)
        sodiumMg = items.map(\.sodiumMg).reduce(0, +)
        fluidsMl = items.map(\.fluidsMl).reduce(0, +)
    }
}
