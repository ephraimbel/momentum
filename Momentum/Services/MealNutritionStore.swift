import Foundation
import SwiftData

extension Meal {
    var nutrition: NutritionValues {
        get {
            var n = NutritionValues()
            n[.kcal] = kcal.map(Double.init); n[.carbs] = carbsG.map(Double.init)
            n[.protein] = proteinG.map(Double.init); n[.fat] = fatG.map(Double.init)
            n[.fiber] = fiberG.map(Double.init); n[.sugar] = sugarG.map(Double.init)
            n[.saturatedFat] = satFatG.map(Double.init); n[.sodium] = sodiumMg.map(Double.init)
            n[.potassium] = potassiumMg.map(Double.init); n[.magnesium] = magnesiumMg.map(Double.init)
            n[.iron] = ironMg; n[.calcium] = calciumMg.map(Double.init); n[.fluids] = fluidsMl.map(Double.init)
            if let data = nutritionData, let exact = try? JSONDecoder().decode(NutritionValues.self, from: data) {
                for field in Nutrient.allCases {
                    // A legacy direct scalar edit invalidates that field's cached precision.
                    if let value = exact[field], value.isFinite,
                       (field == .iron ? value == n[field] : exact.integer(field) == n.integer(field)) {
                        n[field] = value
                    }
                }
            }
            return n
        }
        set {
            nutritionData = try? JSONEncoder().encode(newValue)
            kcal = newValue.integer(.kcal); carbsG = newValue.integer(.carbs)
            proteinG = newValue.integer(.protein); fatG = newValue.integer(.fat)
            fiberG = newValue.integer(.fiber); sugarG = newValue.integer(.sugar)
            satFatG = newValue.integer(.saturatedFat); sodiumMg = newValue.integer(.sodium)
            potassiumMg = newValue.integer(.potassium); magnesiumMg = newValue.integer(.magnesium)
            ironMg = newValue[.iron]; calciumMg = newValue.integer(.calcium); fluidsMl = newValue.integer(.fluids)
        }
    }

    var nutritionRows: [NutritionValues] {
        let foods = items
        return foods.isEmpty ? [nutrition] : foods.map(\.exactNutrition)
    }
}

extension MealItem {
    var exactNutrition: NutritionValues {
        guard let basis = portionBasis, basis.quantity.isFinite, basis.quantity > 0,
              qty.isFinite, qty > 0 else { return nutrition }
        var exact = NutritionValues()
        for field in Nutrient.allCases {
            if let value = basis.nutrition[field] {
                let amount = value * qty / basis.quantity
                if amount.isFinite, amount >= 0, amount <= 1_000_000_000 { exact[field] = amount }
            }
        }
        return exact
    }

    var nutrition: NutritionValues {
        get {
            var n = NutritionValues()
            n[.kcal] = Double(kcal); n[.carbs] = Double(carbsG)
            n[.protein] = Double(proteinG); n[.fat] = Double(fatG)
            n[.fiber] = fiberG.map(Double.init); n[.sugar] = sugarG.map(Double.init)
            n[.saturatedFat] = satFatG.map(Double.init); n[.sodium] = Double(sodiumMg)
            n[.potassium] = potassiumMg.map(Double.init); n[.magnesium] = magnesiumMg.map(Double.init)
            n[.iron] = ironMg; n[.calcium] = calciumMg.map(Double.init); n[.fluids] = Double(fluidsMl)
            for field in unknownNutrients ?? [] { n[field] = nil }
            return n
        }
        set {
            kcal = newValue.integer(.kcal) ?? 0; carbsG = newValue.integer(.carbs) ?? 0
            proteinG = newValue.integer(.protein) ?? 0; fatG = newValue.integer(.fat) ?? 0
            fiberG = newValue.integer(.fiber); sugarG = newValue.integer(.sugar)
            satFatG = newValue.integer(.saturatedFat); sodiumMg = newValue.integer(.sodium) ?? 0
            potassiumMg = newValue.integer(.potassium); magnesiumMg = newValue.integer(.magnesium)
            ironMg = newValue[.iron]; calciumMg = newValue.integer(.calcium); fluidsMl = newValue.integer(.fluids) ?? 0
            unknownNutrients = Nutrient.allCases.filter { newValue[$0] == nil }
        }
    }
}

@MainActor
enum MealNutritionStore {
    /// Injectable save operation allows failure tests without relying on a full disk.
    static func insert(_ meal: Meal, in context: ModelContext,
                       save: (() throws -> Void)? = nil) throws {
        context.insert(meal)
        do { try save?() ?? context.save() }
        catch {
            context.delete(meal) // cancel this unsaved insertion, preserving unrelated edits
            throw error
        }
    }

    static func update(_ meal: Meal, in context: ModelContext,
                       save: (() throws -> Void)? = nil, changes: () -> Void) throws {
        let before = Snapshot(meal)
        changes()
        do { try save?() ?? context.save() }
        catch { before.restore(meal); throw error }
    }

    static func delete(_ meal: Meal, in context: ModelContext) throws {
        // Save outstanding edits before deletion so rollback affects only this operation.
        try context.save()
        context.delete(meal)
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

    private struct Snapshot {
        let text: String
        let eatenAt: Date
        let nutrition: NutritionValues
        let itemsData: Data?
        let source: String
        let note: String?
        let confidence: Double?
        let attempts: Int

        init(_ meal: Meal) {
            text = meal.text; eatenAt = meal.eatenAt; nutrition = meal.nutrition
            itemsData = meal.itemsData; source = meal.source; note = meal.note
            confidence = meal.confidence; attempts = meal.estimateAttempts
        }
        func restore(_ meal: Meal) {
            meal.text = text; meal.eatenAt = eatenAt; meal.nutrition = nutrition
            meal.itemsData = itemsData; meal.source = source; meal.note = note
            meal.confidence = confidence; meal.estimateAttempts = attempts
        }
    }
}
