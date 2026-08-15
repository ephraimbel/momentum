import Foundation
import SwiftData

/// Local-first meal resolution: before the composer ever touches the network, the athlete's own
/// history gets first refusal. Re-typing a meal you have logged before resolves INSTANTLY, offline,
/// for free — the same path the usuals chips already take (FUEL-FLOW §1.5), reached by typing.
///
/// Sits in Services because it is the SwiftData↔engine translation layer (sibling to
/// `FuelReadoutBuilder`); all the judgment lives in the pure `MealTextKey` engine.
@MainActor
enum FuelLocalResolver {

    /// How far back we're willing to look. Bounded by RECENCY, not by time: 300 short strings
    /// normalize in well under a millisecond, and this runs once per send — never in a body pass.
    static let candidateLimit = 300

    /// THE candidate population — the newest `candidateLimit` meals whose numbers actually
    /// resolved. Both remembering paths draw from this ONE function: the typed lookup below and
    /// the usuals chips (`FuelView.computeUsuals`).
    ///
    /// That sharing is load-bearing, not tidiness. The two used to compute their own windows —
    /// the chips walked the newest 200 rows of any kind and filtered afterwards, the lookup
    /// fetched the newest 300 *resolved* rows — so a meal the athlete corrected by hand could sit
    /// inside one window and outside the other. `outranks` puts `manual` first the moment it is
    /// visible, so the same words would resolve to the corrected numbers when TYPED and to a
    /// stale estimate when TAPPED. One population is the only way "the chip and the typed match
    /// produce byte-identical rows" can actually be true.
    ///
    /// The predicate filters BEFORE the limit, so a run of unresolved meals can't push real
    /// candidates out of the window.
    static func candidates(in context: ModelContext) -> [Meal] {
        var descriptor = FetchDescriptor<Meal>(
            predicate: #Predicate<Meal> { $0.carbsG != nil && $0.source != "pending" },
            sortBy: [SortDescriptor(\.eatenAt, order: .reverse)]
        )
        descriptor.fetchLimit = candidateLimit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The remembered meal whose text canonicalizes to the same key, or nil.
    ///
    /// Call this BEFORE inserting the new meal, so the meal being logged can never be its own
    /// candidate. (It also couldn't be — its `carbsG` is still nil — but ordering it first means
    /// the guarantee doesn't depend on that.)
    static func match(for text: String, in context: ModelContext) -> Meal? {
        let key = MealTextKey.normalized(text)
        guard MealTextKey.isMatchable(key) else { return nil }

        let meals = candidates(in: context)
        guard !meals.isEmpty else { return nil }
        let ranked = meals.map {
            MealTextKey.Candidate(key: MealTextKey.normalized($0.text),
                                  isManual: $0.source == "manual",
                                  eatenAt: $0.eatenAt)
        }
        guard let i = MealTextKey.bestMatchIndex(key: key, among: ranked) else { return nil }
        return meals[i]
    }

    /// Copy the remembered numbers onto a fresh meal. This is the single definition of
    /// "re-log this meal" — `repeatMeal` (the usuals chips) calls it too, so a chip tap and a
    /// typed match produce byte-identical rows.
    ///
    /// What is deliberately NOT copied:
    /// - **`note`** — session-specific coach narration ("Good carb bank for tomorrow's long run").
    ///   It narrated a different day's training; carrying it forward would be a fabricated claim,
    ///   and the app never fabricates coaching. A locally-resolved meal simply has no note, which
    ///   is honest: nobody wrote one for today.
    /// - **`text`** — the caller sets the athlete's OWN words for today, so history and search
    ///   read back exactly what they typed, not the phrasing of some earlier day.
    /// - **`photoData` / `eatenAt`** — new meal, new clock, no plate.
    ///
    /// What IS copied and why:
    /// - `itemsData` verbatim as a blob — no JSONDecoder round-trip. The `MealItem.id`s ride along
    ///   duplicated across meals; that is benign (ids are only ever compared *within* one meal, in
    ///   `MealDetailSheet`) and matches the existing `repeatMeal` behaviour.
    /// - all scalar totals — they are Σ items anyway; copying keeps them consistent for free.
    /// - `confidence` — it describes how sure the estimate for this FOOD is, which hasn't changed.
    /// - `source` verbatim ("ai" or "manual") — the provenance genuinely is the earlier estimate or
    ///   the athlete's hand. We deliberately do NOT mint a new `"local"` value: it would buy only
    ///   analytics while adding a third case to every `source ==` check in the feature.
    ///
    /// Free consequence: because `source` is never `"pending"` and `carbsG` is never nil, the
    /// `retryPendingEstimates` filter (`source == "pending" && carbsG == nil`) can never fire for a
    /// locally-resolved meal. No new field, no bookkeeping, no SwiftData migration.
    static func copyNumbers(from source: Meal, to meal: Meal) {
        meal.itemsData = source.itemsData
        meal.kcal = source.kcal
        meal.carbsG = source.carbsG
        meal.proteinG = source.proteinG
        meal.fatG = source.fatG
        meal.sodiumMg = source.sodiumMg
        meal.fluidsMl = source.fluidsMl
        meal.potassiumMg = source.potassiumMg
        meal.magnesiumMg = source.magnesiumMg
        meal.ironMg = source.ironMg
        meal.calciumMg = source.calciumMg
        meal.fiberG = source.fiberG
        meal.sugarG = source.sugarG
        meal.satFatG = source.satFatG
        meal.source = source.source
        meal.confidence = source.confidence
    }

    /// The engine's ranking rule, spoken in `Meal`. Used by the usuals grouping so the chip for a
    /// key and the typed match for that key are the same meal.
    static func outranks(_ a: Meal, _ b: Meal) -> Bool {
        MealTextKey.outranks(aIsManual: a.source == "manual", aEatenAt: a.eatenAt,
                             bIsManual: b.source == "manual", bEatenAt: b.eatenAt)
    }

    /// Rung TWO of the resolution ladder: no history match, but every food phrase is a staple the
    /// deterministic table knows — compose the meal locally and skip the network. Returns false
    /// (meal untouched) when any phrase is a stranger; the AI takes those.
    ///
    /// Provenance: `source = "ai"` — machine-estimated, exactly like the model's answer, just from
    /// a pinned table instead of a prompt (`confidence` 0.9 says which). Deliberately NOT a new
    /// source value, per the precedent on `copyNumbers`: a third case would ripple through every
    /// `source ==` check for an analytics nicety. And like a local hit, no `note` — nobody wrote
    /// coach narration for this meal, and the app never fabricates coaching.
    static func applyStaples(to meal: Meal, text: String) -> Bool {
        guard let items = FoodStaples.compose(text) else { return false }
        meal.items = items.map {
            MealItem(name: $0.name, qty: $0.qty, unit: $0.unit, kcal: $0.kcal,
                     carbsG: $0.carbsG, proteinG: $0.proteinG, fatG: $0.fatG,
                     sodiumMg: $0.sodiumMg, fluidsMl: $0.fluidsMl,
                     potassiumMg: $0.potassiumMg, magnesiumMg: $0.magnesiumMg,
                     ironMg: $0.ironMg, calciumMg: $0.calciumMg,
                     fiberG: $0.fiberG, sugarG: $0.sugarG, satFatG: $0.satFatG, nova: $0.nova)
        }
        meal.source = "ai"
        meal.confidence = FoodStaples.confidence
        return true
    }
}
