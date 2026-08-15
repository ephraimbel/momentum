import Testing
@testable import Momentum

/// Pins the deterministic food-quality judge: fixture foods land in the right bands, the terms
/// move in the right directions, degenerate inputs never crash, and aggregation weights by
/// energy so a glass of water can't launder a processed day.
struct HealthScoreTests {

    // MARK: Fixture foods (the staples table's own values — the numbers athletes actually see)

    private func staple(_ text: String) -> HealthScore.Facts {
        let item = FoodStaples.item(for: text)!
        return HealthScore.Facts(name: item.name, kcal: item.kcal, carbsG: item.carbsG,
                                 proteinG: item.proteinG, fatG: item.fatG,
                                 sodiumMg: item.sodiumMg, fiberG: item.fiberG,
                                 sugarG: item.sugarG, satFatG: item.satFatG,
                                 potassiumMg: item.potassiumMg, nova: item.nova)
    }

    @Test func wholeFoodsScoreWhole() {
        for text in ["banana", "oatmeal", "avocado", "apple", "greek yogurt", "egg", "chicken breast"] {
            let v = HealthScore.score(staple(text))
            #expect(v.band == .whole, "\(text) scored \(v.score)")
        }
    }

    @Test func ultraProcessedScoresProcessed() {
        for text in ["gel", "soda", "donut", "muffin"] {
            let v = HealthScore.score(staple(text))
            #expect(v.band == .processed, "\(text) scored \(v.score)")
        }
    }

    @Test func middleFoodsLandBetween() {
        // Refined-but-modest and mixed foods must not collapse to either extreme.
        for text in ["toast", "slice pizza", "chocolate milk", "protein bar", "butter"] {
            let v = HealthScore.score(staple(text))
            #expect(v.band == .solid || v.band == .mixed, "\(text) scored \(v.score)")
        }
    }

    @Test func waterReadsWholeAndZeroCalUltraProcessedReadsHonest() {
        #expect(HealthScore.score(staple("water")).band == .whole)
        // A zero-cal ultra-processed drink (diet soda shape) is named for what it is.
        let diet = HealthScore.Facts(name: "Diet Soda", kcal: 0, nova: 4)
        #expect(HealthScore.score(diet).band == .processed)
    }

    // MARK: Term directions

    @Test func sugarDragsAndNovaSoftensIntrinsicSugar() {
        var processed = HealthScore.Facts(kcal: 200, carbsG: 50, sugarG: 40, nova: 4)
        var fruit = processed
        fruit.nova = 1
        #expect(HealthScore.score(fruit).score > HealthScore.score(processed).score)
        // More sugar can never raise a score, all else equal.
        var sweeter = processed
        sweeter.sugarG = 50
        #expect(HealthScore.score(sweeter).score <= HealthScore.score(processed).score)
    }

    @Test func fiberAndProteinLift() {
        let plain = HealthScore.Facts(kcal: 200, carbsG: 40)
        var fibrous = plain; fibrous.fiberG = 6
        var proteic = plain; proteic.proteinG = 15
        #expect(HealthScore.score(fibrous).score > HealthScore.score(plain).score)
        #expect(HealthScore.score(proteic).score > HealthScore.score(plain).score)
    }

    @Test func sodiumOnlyDingsOutsizedLoads() {
        // The electrolyte lane (300 mg tab, 230 mg bottle) must never trip the sodium term.
        let tab = HealthScore.score(staple("electrolyte tab"))
        #expect(!tab.drivers.contains { $0.kind == .sodium })
        var salty = HealthScore.Facts(kcal: 300, carbsG: 30, sodiumMg: 1400)
        var mild = salty; mild.sodiumMg = 400
        #expect(HealthScore.score(salty).score < HealthScore.score(mild).score)
    }

    @Test func allNilQualityFieldsStillScore() {
        // A pre-field meal (macros only) degrades gracefully — scores, never crashes, stays sane.
        let legacy = HealthScore.Facts(kcal: 600, carbsG: 70, proteinG: 25, fatG: 20, sodiumMg: 800)
        let v = HealthScore.score(legacy)
        #expect((0...100).contains(v.score))
    }

    @Test func scoresClampToTheScale() {
        let angelic = HealthScore.Facts(kcal: 100, carbsG: 20, proteinG: 20, fatG: 0,
                                        fiberG: 10, sugarG: 0, satFatG: 0, potassiumMg: 900, nova: 1)
        let cursed = HealthScore.Facts(kcal: 100, carbsG: 25, proteinG: 0, fatG: 5,
                                       sodiumMg: 2400, fiberG: 0, sugarG: 25, satFatG: 5, nova: 4)
        #expect(HealthScore.score(angelic).score <= 100)
        #expect(HealthScore.score(cursed).score >= 0)
    }

    // MARK: Aggregation

    @Test func aggregateWeightsByEnergy() {
        let feast = [staple("donut"), staple("water")]
        // Water (20-weight floor) must barely move a 260-kcal donut's day.
        let alone = HealthScore.score(staple("donut")).score
        let together = HealthScore.aggregate(feast)!.score
        #expect(abs(together - alone) <= 8)
        #expect(HealthScore.aggregate([]) == nil)
    }

    @Test func mealOfWholeFoodsAggregatesWhole() {
        let breakfast = [staple("2 eggs"), staple("banana"), staple("coffee")]
        #expect(HealthScore.aggregate(breakfast)!.band == .whole)
    }

    // MARK: Day analysis + language

    @Test func dayAnalysisCountsBandsAndFlagsSportsFuel() {
        let day = HealthScore.day([staple("banana"), staple("gel"), staple("oatmeal")])!
        #expect(day.itemCount == 3)
        #expect(day.bandCounts[.whole] == 2)
        #expect(day.bandCounts[.processed] == 1)
        #expect(day.sportsFuelPresent)
        let quiet = HealthScore.day([staple("banana")])!
        #expect(!quiet.sportsFuelPresent)
    }

    @Test func driverSourcesNameTheFoodsThatCarriedEachDriver() {
        // A soda-and-oats day: the sugar drag must point at the soda, the fiber lift at the
        // oatmeal — the attribution is the page's whole "why".
        let day = HealthScore.day([staple("oatmeal"), staple("soda"), staple("banana")])!
        #expect(day.driverSources[.sugars]?.first == "Soda")
        #expect(day.driverSources[.fiber]?.contains("Oatmeal") == true)
        #expect(day.driverSources[.ultraProcessed]?.first == "Soda")
        // ≤2 names per driver, and a nameless pseudo-item never appears.
        for names in day.driverSources.values { #expect(names.count <= 2) }
        let anon = HealthScore.day([HealthScore.Facts(kcal: 300, carbsG: 40, sugarG: 30, nova: 4)])!
        #expect(anon.driverSources[.sugars]?.isEmpty ?? true)
    }

    @Test func driversLineNamesTheMovers() {
        let v = HealthScore.score(staple("banana"))
        let line = HealthScore.driversLine(v.drivers)
        #expect(line?.contains("Lifted by") == true)
        let bad = HealthScore.score(staple("soda"))
        #expect(HealthScore.driversLine(bad.drivers)?.contains("Dragged by") == true)
    }

    @Test func headlinesNeverShame() {
        // Band words and headlines stay descriptive — no diet/weight/failure language.
        for band in HealthScore.Band.allCases {
            #expect(!["bad", "fail", "unhealthy"].contains(band.word.lowercased()))
        }
        let day = HealthScore.day([staple("soda"), staple("donut")])!
        for banned in ["diet", "weight", "calorie-cutting", "failed"] {
            #expect(!day.headline.lowercased().contains(banned))
        }
    }

    // MARK: The staples table carries the quality fields

    @Test func staplesCarryNovaAndSugarWhereItMatters() {
        #expect(staple("gel").nova == 4)
        #expect(staple("banana").nova == 1)
        #expect(staple("sports drink").sugarG == 34)
        #expect(staple("avocado").fiberG == 10)
        // Quantities scale quality grams but never the class.
        let two = FoodStaples.item(for: "2 bananas")!
        #expect(two.sugarG == 28)
        #expect(two.nova == 1)
    }
}
