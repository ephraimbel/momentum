import Foundation

/// The pure half of barcode meal logging: Open Food Facts JSON → a `ScannedProduct`, and a
/// `ScannedProduct` × servings → the numbers a `MealItem` carries. No networking, no camera —
/// every judgment here is unit-tested against pinned fixtures (the same doctrine as `FoodStaples`:
/// a wrong number silently logged is the failure mode, so the math lives where tests can see it).
///
/// Label data is ground truth, not an estimate — the scanned meal saves as `source = "manual"`
/// with confidence 1, so it outranks any earlier AI guess for the same words in the history rung
/// (`MealTextKey.outranks`), exactly like a hand correction.
enum BarcodeFood {

    /// One scanned product, reduced to what the confirm card and the meal need. Values are per
    /// ONE serving on the basis stated — `servingDescription` tells the athlete what "a serving"
    /// means ("22 g bar", or "100 g" when the label gave no serving split).
    struct ScannedProduct: Equatable, Sendable {
        var barcode: String
        var name: String
        var brand: String?
        var servingDescription: String
        var kcal: Double
        var carbsG: Double
        var proteinG: Double
        var fatG: Double
        var sodiumMg: Double
        // Micros are nil-preserving end to end (`Meal.applyTotals` doctrine): a label that
        // doesn't declare potassium means UNKNOWN, and storing 0 would read as a measured zero.
        var potassiumMg: Double?
        var calciumMg: Double?
        var ironMg: Double?
    }

    /// Decode an Open Food Facts v2 product response. Returns nil when the product is missing,
    /// unnamed, or carries no usable energy value — a card with a name and all-zero numbers would
    /// read as "this food is free", which is worse than an honest miss.
    ///
    /// Basis rule: per-SERVING values win when the label declares them (that is what the athlete
    /// eats); otherwise per-100 g with the serving description saying so. OFF reports sodium,
    /// potassium and calcium in GRAMS — converted to mg here, matching `Meal`'s SI-at-rest rule.
    static func product(fromOFF data: Data, barcode: String) -> ScannedProduct? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["status"] as? Int) == 1,
              let product = root["product"] as? [String: Any] else { return nil }

        let rawName = (product["product_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawName.isEmpty else { return nil }
        // OFF brands is a comma list ("Kellogg's, Kellogg Company") — the first is the label name.
        let brand = (product["brands"] as? String)?
            .split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }

        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        // OFF values arrive as numbers OR strings ("409" and 409 are both in the wild).
        func value(_ key: String, _ basis: String) -> Double? {
            let raw = nutriments["\(key)_\(basis)"]
            if let n = raw as? NSNumber { return n.doubleValue }
            if let s = raw as? String { return Double(s) }
            return nil
        }
        // Energy ladder: kcal when declared; some labels carry only kJ ("energy" is kJ in OFF).
        func kcalValue(_ basis: String) -> Double? {
            value("energy-kcal", basis) ?? value("energy", basis).map { $0 * 0.2390 }
        }
        // Sodium ladder: EU labels declare salt, not sodium — sodium = salt ÷ 2.5.
        func sodiumG(_ basis: String) -> Double? {
            value("sodium", basis) ?? value("salt", basis).map { $0 / 2.5 }
        }

        let perServing = kcalValue("serving") != nil
        let basis = perServing ? "serving" : "100g"
        guard let kcal = kcalValue(basis), kcal >= 0, kcal < 5000 else { return nil }
        // NO fabricated numbers, ever: a label that doesn't declare all three macros declines to
        // "describe it instead" rather than render invented zeros as measured label truth. (Real
        // zeros pass — a diet soda declares 0/0/0 explicitly.)
        guard let carbs = value("carbohydrates", basis),
              let protein = value("proteins", basis),
              let fat = value("fat", basis) else { return nil }

        let servingSize = (product["serving_size"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let servingDescription = perServing ? (servingSize ?? "1 serving") : "100 g"

        return ScannedProduct(
            barcode: barcode,
            name: rawName,
            brand: brand,
            servingDescription: servingDescription,
            kcal: kcal,
            carbsG: carbs,
            proteinG: protein,
            fatG: fat,
            sodiumMg: (sodiumG(basis) ?? 0) * 1000,
            potassiumMg: value("potassium", basis).map { $0 * 1000 },
            calciumMg: value("calcium", basis).map { $0 * 1000 },
            ironMg: value("iron", basis).map { $0 * 1000 }   // OFF stores grams; mg is ours
        )
    }

    /// The meal-item numbers for `servings` of a product — one rounding rule, shared by the
    /// confirm card's live readout and the saved meal so they can never disagree.
    struct Portion: Equatable {
        var kcal: Int
        var carbsG: Int
        var proteinG: Int
        var fatG: Int
        var sodiumMg: Int
        var potassiumMg: Int?
        var calciumMg: Int?
        var ironMg: Double?
    }

    static func portion(of p: ScannedProduct, servings: Double) -> Portion {
        func scaled(_ v: Double) -> Int { Int((v * servings).rounded()) }
        return Portion(kcal: scaled(p.kcal),
                       carbsG: scaled(p.carbsG),
                       proteinG: scaled(p.proteinG),
                       fatG: scaled(p.fatG),
                       sodiumMg: scaled(p.sodiumMg),
                       potassiumMg: p.potassiumMg.map(scaled),
                       calciumMg: p.calciumMg.map(scaled),
                       ironMg: p.ironMg.map { ($0 * servings * 10).rounded() / 10 })
    }

    /// The logged meal's text — the athlete's history reads like they wrote it themselves, and
    /// the same words typed later hit the history rung and copy these label numbers.
    static func mealText(for p: ScannedProduct, servings: Double) -> String {
        let name = [p.brand, p.name].compactMap { $0 }.joined(separator: " ")
        guard servings != 1 else { return name }
        let qty = servings.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(servings)) : String(servings)
        return "\(qty) x \(name)"
    }

    /// A plausible retail food barcode: the symbologies the capture session accepts can also read
    /// coupons and shipping labels — length-gate before spending a network call.
    static func isLikelyFoodBarcode(_ code: String) -> Bool {
        (8...14).contains(code.count) && code.allSatisfy(\.isNumber)
    }
}
