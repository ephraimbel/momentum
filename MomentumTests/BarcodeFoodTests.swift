import Foundation
import Testing
@testable import Momentum

/// The barcode lane's pure half. Same stakes as `FoodStaplesTests`: a wrong number silently
/// logged as "label truth" is the failure mode, so every decode judgment is pinned here against
/// real Open Food Facts response shapes.
@Suite("BarcodeFood")
struct BarcodeFoodTests {

    private func off(_ productJSON: String, status: Int = 1) -> Data {
        Data(#"{"code":"0016000275270","status":\#(status),"product":\#(productJSON)}"#.utf8)
    }

    // MARK: Decode

    @Test("Per-serving values win when the label declares them")
    func perServingWins() throws {
        let data = off(#"""
        {"product_name":"Rice Krispies Treats","brands":"Kellogg's, Kellogg Company",
         "serving_size":"22 g",
         "nutriments":{"energy-kcal_serving":90,"energy-kcal_100g":409,
                       "carbohydrates_serving":17,"carbohydrates_100g":77.3,
                       "proteins_serving":0.7,"fat_serving":2.3,
                       "sodium_serving":0.105,"sodium_100g":0.477}}
        """#)
        let p = try #require(BarcodeFood.product(fromOFF: data, barcode: "0016000275270"))
        #expect(p.name == "Rice Krispies Treats")
        #expect(p.brand == "Kellogg's")                    // first of the comma list
        #expect(p.servingDescription == "22 g")
        #expect(p.kcal == 90)                              // serving, not 409/100g
        #expect(p.carbsG == 17)
        #expect(abs(p.sodiumMg - 105) < 0.001)             // OFF grams → mg
        #expect(p.potassiumMg == nil)                      // undeclared micro stays unknown
    }

    @Test("Falls back to per-100g, and says so in the serving description")
    func per100gFallback() throws {
        let data = off(#"""
        {"product_name":"Granola","brands":"Store Brand",
         "nutriments":{"energy-kcal_100g":450,"carbohydrates_100g":60,
                       "proteins_100g":10,"fat_100g":18,"sodium_100g":0.02}}
        """#)
        let p = try #require(BarcodeFood.product(fromOFF: data, barcode: "12345678"))
        #expect(p.kcal == 450)
        #expect(p.servingDescription == "100 g")
        #expect(abs(p.sodiumMg - 20) < 0.001)
    }

    @Test("EU labels: kJ-only energy converts, salt-only sodium converts, string numbers parse")
    func euLabelLadders() throws {
        let data = off(#"""
        {"product_name":"Haferflocken","brands":"Alnatura",
         "nutriments":{"energy_100g":"1568","carbohydrates_100g":"58.7",
                       "proteins_100g":13.5,"fat_100g":7,"salt_100g":0.02}}
        """#)
        let p = try #require(BarcodeFood.product(fromOFF: data, barcode: "4104420033986"))
        #expect(abs(p.kcal - 374.8) < 0.5)                 // 1568 kJ × 0.2390
        #expect(abs(p.carbsG - 58.7) < 0.001)              // string number parsed
        #expect(abs(p.sodiumMg - 8) < 0.001)               // salt 0.02 g ÷ 2.5 → g → mg
    }

    @Test("Unknown product, missing name, or absurd energy decline honestly")
    func declines() {
        #expect(BarcodeFood.product(fromOFF: off(#"{}"#, status: 0), barcode: "1") == nil)
        #expect(BarcodeFood.product(fromOFF: off(#"{"product_name":"  ","nutriments":{"energy-kcal_100g":100}}"#),
                                    barcode: "12345678") == nil)
        #expect(BarcodeFood.product(fromOFF: off(#"{"product_name":"Bar","nutriments":{}}"#),
                                    barcode: "12345678") == nil)      // no energy → no card
        #expect(BarcodeFood.product(fromOFF: off(#"{"product_name":"Bar","nutriments":{"energy-kcal_100g":99999}}"#),
                                    barcode: "12345678") == nil)      // absurd energy
        #expect(BarcodeFood.product(fromOFF: Data("not json".utf8), barcode: "1") == nil)
    }

    // MARK: Portion math

    private var treat: BarcodeFood.ScannedProduct {
        .init(barcode: "0038000236204", name: "Rice Krispies Treats", brand: "Kellogg's",
              servingDescription: "22 g", kcal: 90, carbsG: 17, proteinG: 0.7, fatG: 2.3,
              sodiumMg: 105, potassiumMg: nil, calciumMg: nil, ironMg: nil)
    }

    @Test("Servings scale every number with one rounding rule; nil micros stay nil")
    func portionScales() {
        let half = BarcodeFood.portion(of: treat, servings: 0.5)
        #expect(half.kcal == 45)
        #expect(half.carbsG == 9)          // 8.5 rounds away from zero, like FoodStaples
        #expect(half.sodiumMg == 53)
        #expect(half.potassiumMg == nil)

        let two = BarcodeFood.portion(of: treat, servings: 2)
        #expect(two.kcal == 180 && two.carbsG == 34)
    }

    @Test("The logged text reads like the athlete wrote it")
    func mealText() {
        #expect(BarcodeFood.mealText(for: treat, servings: 1) == "Kellogg's Rice Krispies Treats")
        #expect(BarcodeFood.mealText(for: treat, servings: 2) == "2 x Kellogg's Rice Krispies Treats")
        #expect(BarcodeFood.mealText(for: treat, servings: 1.5) == "1.5 x Kellogg's Rice Krispies Treats")
        var unbranded = treat
        unbranded.brand = nil
        #expect(BarcodeFood.mealText(for: unbranded, servings: 1) == "Rice Krispies Treats")
    }

    // MARK: Barcode plausibility

    @Test("Only retail-food-shaped codes reach the network")
    func barcodeGate() {
        #expect(BarcodeFood.isLikelyFoodBarcode("0038000236204"))    // UPC-A as EAN-13
        #expect(BarcodeFood.isLikelyFoodBarcode("96385074"))         // EAN-8
        #expect(!BarcodeFood.isLikelyFoodBarcode("1234567"))         // too short
        #expect(!BarcodeFood.isLikelyFoodBarcode("123456789012345"))// too long
        #expect(!BarcodeFood.isLikelyFoodBarcode("ABC-123-XYZ"))     // not a retail food code
        #expect(!BarcodeFood.isLikelyFoodBarcode(""))
    }
}
