import Foundation
import Testing
@testable import Momentum

/// The deterministic staples table — rung two of the meal-resolution ladder. The stakes mirror
/// `MealTextKeyTests`: a MISS costs one cheap API call; a WRONG COMPOSE silently logs someone
/// else's nutrition into the athlete's day. The negative cases are the load-bearing half.
@Suite("FoodStaples")
struct FoodStaplesTests {

    // MARK: Composes

    @Test func classicBreakfastComposes() throws {
        let items = try #require(FoodStaples.compose("2 eggs, toast, coffee"))
        #expect(items.count == 3)
        #expect(items[0].name == "Egg" && items[0].qty == 2 && items[0].kcal == 144)
        #expect(items[1].name == "Toast" && items[1].kcal == 75)
        #expect(items[2].name == "Coffee" && items[2].fluidsMl == 240)
    }

    @Test func rewordingComposesIdentically() throws {
        let a = try #require(FoodStaples.compose("2 eggs, toast, coffee"))
        let b = try #require(FoodStaples.compose("2 eggs and toast with coffee"))
        #expect(a == b)
    }

    @Test func quantitiesScaleLinearly() throws {
        let gels = try #require(FoodStaples.compose("3 gels"))
        #expect(gels[0].qty == 3 && gels[0].kcal == 300 && gels[0].carbsG == 69)
        let half = try #require(FoodStaples.compose("1/2 banana"))
        #expect(half[0].qty == 0.5 && half[0].kcal == 53)   // 105 × 0.5 rounds away from zero
    }

    @Test func numberWordsCount() throws {
        let two = try #require(FoodStaples.compose("two gels"))
        #expect(two[0].qty == 2 && two[0].kcal == 200)
    }

    @Test func pluralAndSingularAreTheSameFood() throws {
        let one = try #require(FoodStaples.compose("egg"))
        let many = try #require(FoodStaples.compose("eggs"))
        #expect(one[0].name == many[0].name)
        #expect(one[0].qty == 1 && many[0].qty == 1)
    }

    @Test func fillerWordsDontBlockTheLookup() throws {
        // "a glass of milk" → filler-stripped to "glass milk", an explicit alias.
        let milk = try #require(FoodStaples.compose("a glass of milk"))
        #expect(milk[0].name == "Milk" && milk[0].fluidsMl == 244)
    }

    @Test func fluidsRideAlong() throws {
        let water = try #require(FoodStaples.compose("water"))
        #expect(water[0].kcal == 0 && water[0].fluidsMl == 250)
    }

    @Test func microsRideAlongAndScale() throws {
        // The Today card displays micros against their floors (2026-07-22), so a staple banana
        // must carry its potassium like an AI-estimated one — and scale with quantity.
        let banana = try #require(FoodStaples.compose("banana"))
        #expect(banana[0].potassiumMg == 422 && banana[0].magnesiumMg == 32)
        let eggs = try #require(FoodStaples.compose("2 eggs"))
        #expect(eggs[0].potassiumMg == 138 && eggs[0].ironMg == 1.8 && eggs[0].calciumMg == 56)
    }

    @Test func everyStarterComposes() {
        // The quick-log chips promise instant, $0 logging — a table edit must never orphan one.
        for starter in FoodStaples.starters {
            #expect(FoodStaples.compose(starter) != nil, "starter \"\(starter)\" must compose")
        }
    }

    @Test func aliasesAreUnique() {
        // A duplicate alias would silently shadow a food — curation bug, caught here.
        #expect(FoodStaples.aliasCount == FoodStaples.uniqueAliasCount)
    }

    // MARK: Declines (precision over recall — these falling through to the AI is the design)

    @Test func platedMealsDecline() {
        #expect(FoodStaples.compose("big pasta dinner with chicken") == nil)
        #expect(FoodStaples.compose("chicken rice bowl") == nil)
    }

    @Test func oneStrangerKillsTheWholeCompose() {
        #expect(FoodStaples.compose("2 eggs, dragonfruit smoothie") == nil)
    }

    @Test func ratiosAreNotQuantities() {
        // "2:1" is a carb-mix ratio welded into the food text by MealTextKey — never a count.
        #expect(FoodStaples.compose("2:1 carb drink") == nil)
    }

    @Test func absurdQuantitiesDecline() {
        #expect(FoodStaples.compose("0.1 banana") == nil)
        #expect(FoodStaples.compose("150 gels") == nil)
    }

    @Test func emptyAndUnmatchableDecline() {
        #expect(FoodStaples.compose("") == nil)
        #expect(FoodStaples.compose("   ") == nil)
        #expect(FoodStaples.compose("!!!") == nil)
    }
}

/// `segments` is `normalized`'s exposed midpoint — pin the order-preserving contract the staples
/// parser consumes, and the identity that keeps the two from ever drifting.
@Suite("MealTextKeySegments")
struct MealTextKeySegmentsTests {

    @Test func joinersAndCommasSegmentAlike() {
        #expect(MealTextKey.segments("2 eggs and toast with coffee") == ["2 eggs", "toast", "coffee"])
        #expect(MealTextKey.segments("2 eggs, toast, coffee") == ["2 eggs", "toast", "coffee"])
    }

    @Test func orderAndDuplicatesSurvive() {
        #expect(MealTextKey.segments("coffee, coffee") == ["coffee", "coffee"])
        #expect(MealTextKey.segments("toast, 2 eggs") == ["toast", "2 eggs"])
    }

    @Test func normalizedIsSortedJoinedSegments() {
        let raw = "toast w/ butter, 2 eggs. coffee"
        #expect(MealTextKey.normalized(raw)
            == MealTextKey.segments(raw).sorted().joined(separator: " | "))
    }
}
