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
        c.potassiumMg = potassiumMg.map { Int((Double($0) * f).rounded()) }
        c.magnesiumMg = magnesiumMg.map { Int((Double($0) * f).rounded()) }
        c.ironMg = ironMg.map { ($0 * f * 10).rounded() / 10 }
        c.calciumMg = calciumMg.map { Int((Double($0) * f).rounded()) }
        c.fiberG = fiberG.map { Int((Double($0) * f).rounded()) }
        c.sugarG = sugarG.map { Int((Double($0) * f).rounded()) }
        c.satFatG = satFatG.map { Int((Double($0) * f).rounded()) }
        // `nova` classifies the food, not the amount — it rides along unscaled.
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
        guard !items.isEmpty else { return }
        kcal = items.map(\.kcal).reduce(0, +)
        carbsG = items.map(\.carbsG).reduce(0, +)
        proteinG = items.map(\.proteinG).reduce(0, +)
        fatG = items.map(\.fatG).reduce(0, +)
        sodiumMg = items.map(\.sodiumMg).reduce(0, +)
        fluidsMl = items.map(\.fluidsMl).reduce(0, +)
        // Micros stay nil-preserving. Since 2026-07-21 the estimator no longer returns them
        // (docs/FUEL-FLOW.md), so every item carries nil and an all-nil set must sum to nil,
        // not 0 — a stored 0 would read as a measured zero to any future micro surface rather
        // than as "never estimated". Historical meals that DO carry values still sum normally.
        potassiumMg = Self.optionalSum(items.compactMap(\.potassiumMg))
        magnesiumMg = Self.optionalSum(items.compactMap(\.magnesiumMg))
        ironMg = Self.optionalSum(items.compactMap(\.ironMg))
        calciumMg = Self.optionalSum(items.compactMap(\.calciumMg))
        fiberG = Self.optionalSum(items.compactMap(\.fiberG))
        sugarG = Self.optionalSum(items.compactMap(\.sugarG))
        satFatG = Self.optionalSum(items.compactMap(\.satFatG))
    }

    /// Σ, but nil for an empty set — keeps "no data" distinct from a real zero.
    private static func optionalSum<N: AdditiveArithmetic>(_ values: [N]) -> N? {
        values.isEmpty ? nil : values.reduce(N.zero, +)
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
