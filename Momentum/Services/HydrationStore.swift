import Foundation
import SwiftData

@MainActor
enum HydrationStore {
    /// Search the whole stored journal, including dates outside Fuel's recent-entry window.
    static func moveWater(in context: ModelContext) throws {
        let query = FetchDescriptor<Meal>(predicate: #Predicate { $0.kcal == 0 })
        try moveWater(from: context.fetch(query), in: context)
    }

    /// Reclassify older water-only meal rows without duplicating water or changing its date.
    /// This is idempotent and also handles an estimator that identifies a water-only drink.
    static func moveWater(from meals: [Meal], in context: ModelContext) throws {
        let candidates = meals.filter {
            guard !$0.isDeleted, ($0.fluidsMl ?? 0) > 0, $0.kcal == 0,
                  ($0.carbsG ?? 0) == 0, ($0.proteinG ?? 0) == 0, ($0.fatG ?? 0) == 0 else { return false }
            // Keep nutrient-bearing drinks intact; moving them into a water-only record
            // must never discard declared electrolytes or minerals.
            let nutrition = $0.nutrition
            guard Nutrient.allCases.filter({ $0 != .fluids }).allSatisfy({ (nutrition[$0] ?? 0) == 0 }) else { return false }
            let foods = $0.items
            let names = foods.isEmpty ? [$0.text] : foods.map(\.name)
            return names.allSatisfy { name in
                let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return ["water", "sparkling water", "mineral water", "tap water", "bottled water"].contains(value)
                    || value.range(of: #"^water, [0-9]+ ml$"#, options: .regularExpression) != nil
            }
        }
        guard !candidates.isEmpty else { return }
        try context.save()
        let existing = Set(try context.fetch(FetchDescriptor<WaterEntry>()).map(\.id))
        for meal in candidates {
            if !existing.contains(meal.id) {
                let water = WaterEntry(amountMl: meal.nutrition[.fluids] ?? Double(meal.fluidsMl ?? 0), drankAt: meal.eatenAt)
                water.id = meal.id
                context.insert(water)
            }
            context.delete(meal)
        }
        do { try context.save() }
        catch { context.rollback(); throw error }
    }
}
