import Foundation
import SwiftData

/// One logged meal, snack, or drink — the FUEL pillar (decision 2026-07-16, extends ENDURANCE-FOCUS
/// §11 from guidance to tracking). Deliberately athlete-framed: the numbers exist to answer "am I
/// fueled for the work?", never to run a diet ledger. Energy is a FLOOR (fund the training), carbs
/// are the readiness signal, protein the recovery signal, sodium the endurance electrolyte. No
/// weight-loss framing anywhere, ever.
///
/// A meal saves instantly offline — one sentence in the athlete's own words. The `meal-estimate` Edge Function
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
    // Endurance micros (2026-07-16): potassium pairs sodium, iron carries oxygen (the runner's
    // micro), calcium guards bone (the RED-S story), magnesium works the muscle. All ≈, all floors.
    var potassiumMg: Int?
    var magnesiumMg: Int?
    var ironMg: Double?
    var calciumMg: Int?
    // Food-quality signals (2026-08-15, the health-score pass): fiber lifts, total sugars and
    // saturated fat drag, and together with per-item NOVA class they feed the deterministic
    // `HealthScore` engine. All defaulted-nil (implicit lightweight migration only) and
    // nil-preserving like every micro — nil is "not estimated", never zero.
    var fiberG: Int?
    var sugarG: Int?
    var satFatG: Int?

    /// The itemized breakdown ("2 eggs · toast · coffee"), JSON-encoded `[MealItem]` — the same
    /// blob pattern as `structuredRepsData`. Totals on the meal are ALWAYS Σ items when items
    /// exist (kept in scalar fields so `FuelReadiness` and queries never decode JSON).
    var itemsData: Data?
    /// Exact label/manual totals; scalar fields remain rounded for existing readout contracts.
    /// Optional for lightweight migration of journals created before fractional entry.
    var nutritionData: Data?

    /// "ai" | "manual" | "pending" — provenance of the numbers. Manual always wins.
    var source: String = "pending"
    /// One coach-toned line from the estimator ("Solid pre-long-run fuel."). Display only.
    var note: String?
    /// Estimator confidence 0–1 (surfaced as a quiet "≈" — every number here is approximate).
    var confidence: Double?
    /// How many times the estimator has been fired for this meal. Bounded retry: the journal stops
    /// re-firing after `FuelView.maxEstimateAttempts`, so a meal the model simply can't parse never
    /// becomes a permanent API tax on every tab visit; a deliberate "Estimate again" resets it.
    /// Defaulted, like every property on this model — implicit lightweight migration only.
    var estimateAttempts: Int = 0

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
    // Optional so blobs itemized before the micros existed still decode.
    var potassiumMg: Int?
    var magnesiumMg: Int?
    var ironMg: Double?
    var calciumMg: Int?
    // Food-quality signals (2026-08-15) — optional for the same reason. `nova` is the NOVA
    // processing classification 1–4 (1 whole food … 4 ultra-processed), the strongest single
    // input to the deterministic `HealthScore`; it describes the FOOD, so portion scaling
    // never touches it.
    var fiberG: Int?
    var sugarG: Int?
    var satFatG: Int?
    var nova: Int?

    /// Missing label fields and a stable portion basis are optional for old stored blobs.
    var unknownNutrients: [Nutrient]?
    var portionBasis: MealPortionBasis?
    var servingDescription: String?

    /// Scale from the original numbers, never from an already-rounded portion.
    func scaled(to newQty: Double) -> MealItem {
        guard newQty.isFinite, newQty > 0, newQty <= 10_000,
              qty.isFinite, qty > 0, newQty != qty else { return self }
        let basis = portionBasis ?? MealPortionBasis(quantity: qty, nutrition: exactNutrition)
        guard basis.quantity.isFinite, basis.quantity > 0 else { return self }
        let factor = newQty / basis.quantity
        var scaled = NutritionValues()
        for field in Nutrient.allCases {
            guard let value = basis.nutrition[field] else { continue }
            let next = value * factor
            guard next.isFinite, next >= 0, next <= 1_000_000_000 else { return self }
            scaled[field] = field == .iron ? (next * 10).rounded() / 10 : next.rounded()
        }
        var copy = self
        copy.qty = newQty
        copy.nutrition = scaled
        copy.portionBasis = basis
        return copy
    }

    /// "2" / "1.5" — quantity with whole numbers kept whole.
    var qtyText: String {
        guard qty.isFinite, qty > 0 else { return "—" }
        return qty.formatted(.number.grouping(.never).precision(.fractionLength(0...3)))
    }

    /// "2 eggs" / "1.5 slices" / "1 cup" — the stepper's portion label. Units pluralize naturally;
    /// abbreviations (oz, ml) never do.
    var portionLabel: String {
        let plural = qty != 1 && !unit.hasSuffix("s") && unit.count > 2 ? "s" : ""
        return "\(qtyText) \(unit)\(plural)"
    }
}

extension Meal {
    /// The journal row's display title: the AI's clean item list once itemized
    /// ("Eggs ×2 · Toast with Butter · Coffee"), else the athlete's own words.
    var journalTitle: String {
        let items = self.items
        guard !items.isEmpty else { return text }
        return items.map { $0.qty == 1 ? $0.name : "\($0.name) ×\($0.qtyText)" }.joined(separator: " · ")
    }

    var items: [MealItem] {
        get { itemsData.flatMap { try? JSONDecoder().decode([MealItem].self, from: $0) } ?? [] }
        set {
            itemsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
            applyTotals(from: newValue)
        }
    }

    /// Totals are ALWAYS Σ items when items exist — one source of truth for the engine.
    func applyTotals(from items: [MealItem]) {
        nutrition = NutritionValues.sum(items.map(\.exactNutrition))
    }

    /// Is running the estimator on this meal capable of doing anything? No numbers yet, and the
    /// athlete hasn't set them by hand (`FuelEstimator.apply` discards its whole response for a
    /// `manual` meal, so firing at one spends a billed call to change nothing).
    ///
    /// THE shared gate: `needsEstimate` is this plus the attempt cap, and the hand-fired
    /// "Estimate again" is this alone — deliberately ignoring the cap, which is the app's limit
    /// and never the athlete's. Two paths, one predicate, so they cannot drift apart.
    var isEstimable: Bool { source != "manual" && carbsG == nil }

    /// A meal the journal should still try on its own: estimable, still honestly `pending`, and
    /// under the attempt cap. Pure and free of SwiftData ceremony so the cap is unit-testable.
    func needsEstimate(maxAttempts: Int) -> Bool {
        isEstimable && source == "pending" && estimateAttempts < maxAttempts
    }
}
