import Foundation
import SwiftData
import Testing
@testable import Momentum

@Suite("Nutrition tracking reliability")
@MainActor
struct MealNutritionTests {
    private func item() -> MealItem {
        MealItem(name: "Toast", qty: 1, unit: "slice", kcal: 101, carbsG: 19,
                 proteinG: 3, fatG: 1, sodiumMg: 123, fluidsMl: 0,
                 potassiumMg: 89, magnesiumMg: 13, ironMg: 1.3, calciumMg: 21,
                 fiberG: 3, sugarG: 1, satFatG: 0)
    }

    @Test func portionsDoNotAccumulateRoundingAcrossEditsAndPersistence() throws {
        let original = item()
        var adjusted = original
        for _ in 0..<20 {
            adjusted = adjusted.scaled(to: 0.5)
            adjusted = try JSONDecoder().decode(MealItem.self, from: JSONEncoder().encode(adjusted))
            adjusted = adjusted.scaled(to: 1)
        }
        #expect(adjusted.nutrition == original.nutrition)
        #expect(adjusted.qty == 1)
        #expect(adjusted.scaled(to: 1.5).kcal == 152)
        #expect(original.scaled(to: 0.25).qtyText == "0.25")
    }

    @Test func invalidPortionsCannotCrashOrCorruptNutrition() {
        let original = item()
        for qty in [Double.nan, .infinity, -.infinity, -1, 0, 100_000] {
            #expect(original.scaled(to: qty) == original)
        }
    }

    @Test func legacyItemBlobsDecodeWithoutNewMetadata() throws {
        let data = Data(#"{"id":"CEB86730-2237-4673-9081-128C13070890","name":"Toast","qty":1,"unit":"slice","kcal":101,"carbsG":19,"proteinG":3,"fatG":1,"sodiumMg":123,"fluidsMl":0}"#.utf8)
        let food = try JSONDecoder().decode(MealItem.self, from: data)
        #expect(food.portionBasis == nil)
        #expect(food.unknownNutrients == nil)
        #expect(food.scaled(to: 2).kcal == 202)
    }

    @Test func removingAllItemsNeverResurrectsOldTotals() {
        let meal = Meal()
        meal.items = [item()]
        #expect(meal.kcal == 101)
        meal.items = []
        #expect(meal.kcal == nil)
        #expect(meal.fluidsMl == nil)
        #expect(meal.itemsData == nil)
    }

    @Test func coverageDistinguishesMissingPartialAndZero() {
        let known = NutritionValues(values: [.kcal: 200, .fiber: 0, .iron: 1.3])
        let missing = NutritionValues(values: [.kcal: 100])
        let fiber = NutritionCoverage.summarize([known, missing], field: .fiber)
        #expect(fiber.total == 0)
        #expect(fiber.known == 1 && !fiber.isComplete)
        #expect(NutritionCoverage.summarize([missing], field: .fiber).total == nil)
        #expect(NutritionCoverage.summarize([known, missing], field: .kcal).total == 300)
        #expect(NutritionCoverage.summarize([known, missing], field: .kcal).isComplete)
    }

    @Test func unknownLabelFieldsStayUnknownThroughPortionsAndTotals() {
        var food = item()
        food.unknownNutrients = [.sodium, .fluids]
        let meal = Meal()
        meal.items = [food.scaled(to: 2)]
        #expect(meal.sodiumMg == nil && meal.fluidsMl == nil)
        #expect(meal.kcal == 202)
    }

    @Test func manualEntryRoundTripsEveryTrackedNutrient() {
        var values = NutritionValues()
        for field in Nutrient.allCases { values[field] = field == .iron ? 2.7 : 25 }
        let parsed = NutritionEntry(values).parsed()
        #expect(parsed.error == nil)
        let meal = Meal()
        meal.nutrition = parsed.values
        #expect(meal.nutrition == values)
        #expect(meal.fluidsMl == 25 && meal.fiberG == 25 && meal.ironMg == 2.7)
    }

    @Test func invalidInputIsRejectedInsteadOfSilentlyClearingSavedValues() {
        for text in ["-1", "nan", "inf", "1e10", "2,000", "1000001", "12abc"] {
            var entry = NutritionEntry()
            entry.fields[.kcal] = text
            #expect(entry.parsed(locale: Locale(identifier: "en_US")).error != nil)
        }
        var entry = NutritionEntry()
        entry.fields[.kcal] = "0"
        #expect(entry.parsed().values[.kcal] == 0)
        #expect(entry.parsed().values[.protein] == nil)
        entry.fields[.iron] = "2,7"
        #expect(entry.parsed(locale: Locale(identifier: "de_DE")).values[.iron] == 2.7)
        entry.fields[.iron] = ""
        entry.fields[.fat] = "5"; entry.fields[.saturatedFat] = "6"
        #expect(entry.parsed().error != nil)
    }

    @Test func separatelyDeclaredFiberDoesNotBlockLabelEntry() {
        let label = NutritionValues(values: [.carbs: 2, .fiber: 8, .sugar: 1])
        #expect(NutritionEntry(label).parsed().error == nil)
        #expect(NutritionEntry(label).parsed().values == label)
    }

    @Test func hydrationAndProteinOnlyMealsCountIndependently() {
        let now = Date()
        let water = FuelReadiness.MealInput(eatenAt: now, kcal: nil, carbsG: nil, proteinG: nil,
                                            sodiumMg: nil, fluidsMl: 500)
        let protein = FuelReadiness.MealInput(eatenAt: now, kcal: nil, carbsG: nil, proteinG: 30,
                                              sodiumMg: nil)
        let readout = FuelReadiness.readout(meals: [water, protein], sessions: [], workoutsToday: [],
                                            bodyMassKg: 70, now: now)
        #expect(readout.fluidsMl == 500)
        #expect(readout.proteinG == 30)
        #expect(readout.kcal == 0 && readout.mealCount == 2)
    }

    @Test func fractionalAmountsSurviveStorageAndRoundOnlyAfterDailySum() throws {
        let pc = PersistenceController.inMemory()
        let context = pc.container.mainContext
        for _ in 0..<3 {
            let meal = Meal()
            meal.nutrition = NutritionValues(values: [.kcal: 10.4, .protein: 0.4, .fat: 0.5])
            try MealNutritionStore.insert(meal, in: context)
        }
        let reloaded = ModelContext(pc.container)
        let meals = try reloaded.fetch(FetchDescriptor<Meal>())
        #expect(meals.allSatisfy { $0.nutrition[.protein] == 0.4 })
        let totals = FuelReadoutBuilder.readout(meals: meals, plan: nil, workouts: [], profile: nil)
        #expect(totals.proteinG == 1)
        #expect(totals.kcal == 31)
        #expect(totals.fatG == 2)
    }

    @Test func versionThreeJournalMigratesWithoutLosingMeals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fuel.store")
        let id = UUID()
        let items = try JSONEncoder().encode([item()])
        try autoreleasepool {
            let schema = Schema(versionedSchema: SchemaV3.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let meal = SchemaV1.Meal()
            meal.id = id; meal.text = "Existing breakfast"; meal.kcal = 101; meal.carbsG = 19
            meal.ironMg = 1.3; meal.itemsData = items; meal.source = "manual"
            meal.note = "Saved before upgrade"; meal.estimateAttempts = 2
            container.mainContext.insert(meal)
            try container.mainContext.save()
        }
        let schema = Schema(versionedSchema: SchemaV4.self)
        let upgraded = try ModelContainer(for: schema, migrationPlan: MomentumMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)])
        let meals = try upgraded.mainContext.fetch(FetchDescriptor<Meal>())
        let meal = try #require(meals.first)
        #expect(meals.count == 1 && meal.id == id)
        #expect(meal.text == "Existing breakfast" && meal.kcal == 101 && meal.ironMg == 1.3)
        #expect(meal.itemsData == items && meal.source == "manual" && meal.estimateAttempts == 2)
        #expect(meal.note == "Saved before upgrade" && meal.nutritionData == nil)
        meal.nutrition = .init(values: [.kcal: 101, .protein: 3.5])
        try upgraded.mainContext.save()
        #expect(meal.nutrition[.protein] == 3.5)
    }

    @Test func waterDoesNotDismissPostWorkoutRefueling() {
        let now = Date()
        let water = FuelReadiness.MealInput(eatenAt: now, kcal: 0, carbsG: 0, proteinG: 0,
                                            fatG: 0, sodiumMg: nil, fluidsMl: 250)
        let readout = FuelReadiness.readout(meals: [water], sessions: [],
            workoutsToday: [.init(endedAt: now.addingTimeInterval(-1200), durationS: 7200, kcal: 900)],
            bodyMassKg: 70, now: now)
        #expect(readout.refuelDue)
    }

    @Test func separateWaterCountsOnlyInFluidsAndNeverCreatesMeals() throws {
        let pc = PersistenceController.inMemory()
        let context = pc.container.mainContext
        let now = Date()
        let water = WaterEntry(amountMl: 250, drankAt: now)
        context.insert(water)
        context.insert(WaterEntry(amountMl: 500, drankAt: now.addingTimeInterval(-172_800)))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Meal>()) == 0)
        let entries = try context.fetch(FetchDescriptor<WaterEntry>())
        let r = FuelReadoutBuilder.readout(meals: [], plan: nil, workouts: [], profile: nil, water: entries, now: now)
        #expect(r.fluidsMl == 250)
        #expect(r.mealCount == 0 && r.kcal == 0 && r.proteinG == 0 && r.carbsG == 0)
        #expect(FuelLocalResolver.candidates(in: context).isEmpty)
        context.delete(water)
        try context.save()
        #expect(WaterEntry.total(try context.fetch(FetchDescriptor<WaterEntry>()), on: now) == 0)
    }

    @Test func legacyWaterMovesOnceWhileMixedMealsStayMeals() throws {
        let pc = PersistenceController.inMemory()
        let context = pc.container.mainContext
        let water = Meal(); water.text = "water"
        #expect(FuelLocalResolver.applyStaples(to: water, text: "water"))
        let id = water.id, time = water.eatenAt
        let lunch = Meal(); lunch.text = "water and toast"
        lunch.items = water.items + [item()]
        context.insert(water); context.insert(lunch); try context.save()
        try HydrationStore.moveWater(in: context)
        try HydrationStore.moveWater(in: context)
        let waters = try context.fetch(FetchDescriptor<WaterEntry>())
        #expect(waters.count == 1 && waters.first?.id == id && waters.first?.drankAt == time)
        #expect(waters.first?.amountMl == 250)
        #expect(try context.fetch(FetchDescriptor<Meal>()).map(\.text) == ["water and toast"])
    }

    @Test func spokenWaterLogsInHydrationAndUndoRemovesIt() throws {
        let pc = PersistenceController.inMemory()
        let context = pc.container.mainContext
        let receipt = try #require(SiriMealLogger.log(text: "water", in: context))
        #expect(receipt.dialog.contains("250 milliliters of water"))
        #expect(try context.fetchCount(FetchDescriptor<Meal>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WaterEntry>()) == 1)
        SiriMealLogger.undoMeal(id: receipt.mealID, in: context)
        #expect(try context.fetchCount(FetchDescriptor<WaterEntry>()) == 0)
        #expect(HydrationInput.milliliters(in: "water and banana") == nil)
    }

    @Test func hydrationReclassificationPreservesRecordedElectrolytes() throws {
        let pc = PersistenceController.inMemory()
        let context = pc.container.mainContext
        let drink = Meal(); drink.text = "water"
        drink.nutrition = NutritionValues(values: [.kcal: 0, .fluids: 500, .sodium: 300])
        context.insert(drink); try context.save()
        try HydrationStore.moveWater(from: [drink], in: context)
        #expect(try context.fetchCount(FetchDescriptor<WaterEntry>()) == 0)
        #expect(try context.fetch(FetchDescriptor<Meal>()).first?.nutrition[.sodium] == 300)
    }

    @Test func explicitWaterVolumesResolveOfflineWithoutMeals() {
        #expect(HydrationInput.milliliters(in: "500 ml water") == 500)
        #expect(HydrationInput.milliliters(in: "1.5 L of water") == 1500)
        #expect(HydrationInput.milliliters(in: "Water, 250 ml") == 250)
        #expect(HydrationInput.milliliters(in: "sparkling water 750ml") == 750)
        #expect(HydrationInput.milliliters(in: "mineral water") == 250)
        #expect(HydrationInput.milliliters(in: "500 ml water and toast") == nil)
        #expect(HydrationInput.milliliters(in: "0 ml water") == nil)
        #expect(HydrationInput.milliliters(in: "999999999999999999999 L water") == nil)
    }

    @Test func dailyReadoutDoesNotTruncateAtEightyOrRequireSortedInput() {
        let now = Date()
        let old = Meal(); old.kcal = 9999; old.eatenAt = now.addingTimeInterval(-172_800)
        let today = (0..<100).map { _ -> Meal in
            let meal = Meal(); meal.kcal = 10; meal.eatenAt = now; return meal
        }
        let readout = FuelReadoutBuilder.readout(meals: [old] + today, plan: nil, workouts: [], profile: nil, now: now)
        #expect(readout.kcal == 1000 && readout.mealCount == 100)
    }

    @Test func tomorrowUsesCalendarDaysAtSpringDSTBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let now = try #require(calendar.date(from: .init(year: 2026, month: 3, day: 7, hour: 23, minute: 30)))
        let tomorrow = try #require(calendar.date(from: .init(year: 2026, month: 3, day: 8, hour: 8)))
        let readout = FuelReadiness.readout(meals: [], sessions: [.init(date: tomorrow, durationS: 7200, isRace: true)],
                                            workoutsToday: [], bodyMassKg: 70, now: now, calendar: calendar)
        #expect(readout.raceEve)
    }

    @Test func saveFailureRestoresOnlyTheMealAndPreservesOtherDrafts() throws {
        let pc = PersistenceController.inMemory()
        let context = pc.container.mainContext
        let meal = Meal(); meal.text = "Original"; meal.items = [item()]
        let other = Meal(); other.text = "Other"
        context.insert(meal); context.insert(other); try context.save()
        other.text = "Unrelated unsaved edit"
        enum Failed: Error { case disk }
        do {
            try MealNutritionStore.update(meal, in: context, save: { throw Failed.disk }) {
                meal.text = "Edited"; meal.items = []; meal.source = "manual"
            }
            Issue.record("Expected save failure")
        } catch {}
        #expect(meal.text == "Original" && meal.kcal == 101 && meal.items.count == 1)
        #expect(other.text == "Unrelated unsaved edit")
    }

    @Test func failedInsertDoesNotCreatePhantomMealOrDuplicateOnRetry() throws {
        let pc = PersistenceController.inMemory()
        let context = pc.container.mainContext
        enum Failed: Error { case disk }
        let first = Meal(); first.text = "Water"; first.fluidsMl = 250
        do {
            try MealNutritionStore.insert(first, in: context, save: { throw Failed.disk })
            Issue.record("Expected save failure")
        } catch {}
        #expect(try context.fetchCount(FetchDescriptor<Meal>()) == 0)
        let retry = Meal(); retry.text = "Water"; retry.fluidsMl = 250
        try MealNutritionStore.insert(retry, in: context)
        #expect(try context.fetchCount(FetchDescriptor<Meal>()) == 1)
    }

    @Test func malformedEstimateLeavesSavedMealUntouched() throws {
        let empty = try JSONDecoder().decode(FuelEstimator.Estimate.self,
            from: Data(#"{"items":[],"confidence":0.8,"note":""}"#.utf8))
        let negative = try JSONDecoder().decode(FuelEstimator.Estimate.self, from: Data(#"{"items":[{"name":"Toast","qty":1,"unit":"slice","kcal":-100,"carbs_g":20,"protein_g":3,"fat_g":1,"sodium_mg":2,"fluids_ml":0}],"confidence":0.8,"note":""}"#.utf8))
        let meal = Meal(); meal.items = [item()]
        for estimate in [empty, negative] {
            #expect(!FuelEstimator.isValid(estimate))
            FuelEstimator.apply(estimate, to: meal)
            #expect(meal.kcal == 101)
        }
    }

    @Test func exportPreservesUnknownsEscapesTextAndBlocksSpreadsheetFormulas() {
        let csv = NutritionCSV.encode([.init(id: UUID(), eatenAt: Date(timeIntervalSince1970: 0),
            name: "=SUM(1,2)\n\"meal\"", source: "manual", nutrition: .init(values: [.kcal: 0, .iron: 1.3]))])
        #expect(csv.contains("\"'=SUM(1,2)\n\"\"meal\"\"\""))
        #expect(csv.contains("1970-01-01T00:00:00Z"))
        #expect(csv.contains(",0,,,,,,,,,,1.3,,"))
        #expect(NutritionCSV.cell("  @SUM(A1)").hasPrefix("\"'"))
    }
}
