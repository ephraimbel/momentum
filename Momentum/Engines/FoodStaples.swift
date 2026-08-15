import Foundation

/// The deterministic staples table — rung two of the meal-resolution ladder (FUEL-FLOW §2:
/// the athlete's own history answers first, this table second, the AI last). When EVERY food
/// phrase in the typed text is a staple this engine knows, the meal composes locally: $0, 0 ms,
/// offline, and correct on day one before any history exists. "2 gels and a banana" should never
/// cost an LLM call.
///
/// **Precision doctrine (same as `MealTextKey`): a miss is cheap, a wrong match is poison.**
/// Every rule can only ever *fail to compose* — never compose the wrong food or the wrong amount:
///  - Exact key match only, against a hand-curated table. No fuzzy matching, no stemming —
///    plural forms are explicit table rows, not an algorithm.
///  - COUNTABLE, STANDARD-PORTION foods only (a gel, an egg, a slice, a banana, a cup). Plated
///    meals — "big pasta dinner", "chicken rice bowl" — are deliberately absent: their portions
///    vary too much for a fixed table, and guessing is the AI's job (it reads context).
///  - One unresolved phrase kills the whole compose. Half-guessed meals don't ship.
///  - Quantities outside a sane 0.25–99 band decline (a "0.1 banana" is a typo, not a portion).
///
/// Values are per-unit USDA-ish middles, commented with their basis. Every number downstream
/// reads "≈" and the athlete's portion steppers outrank everything, so honest middles are enough
/// — `confidence` says exactly how much we trust them.
enum FoodStaples {

    /// A composed food line, plain values — the Services layer (`FuelLocalResolver`) maps these
    /// onto `MealItem` so this engine stays pure. Micros included (2026-07-22): the Today card
    /// displays them against their floors, so a staple-composed banana must carry its potassium
    /// exactly like an AI-estimated one.
    struct Item: Equatable, Sendable {
        let name: String
        let qty: Double
        let unit: String
        let kcal: Int
        let carbsG: Int
        let proteinG: Int
        let fatG: Int
        let sodiumMg: Int
        let fluidsMl: Int
        let potassiumMg: Int
        let magnesiumMg: Int
        let ironMg: Double
        let calciumMg: Int
        // Food-quality signals (2026-08-15) — feed the deterministic `HealthScore`, so a
        // staple-composed banana scores exactly like an AI-estimated one.
        let fiberG: Int
        let sugarG: Int
        let satFatG: Int
        /// NOVA processing class 1–4 — describes the food, never scaled by qty.
        let nova: Int
    }

    /// Curated-table confidence: tighter than a model reading free text (the numbers are pinned,
    /// not guessed), looser than the athlete's own hand (portions still assume the standard unit).
    static let confidence = 0.9

    /// Day-one quick-log chips (shown while the athlete has no usuals of their own — see
    /// `FuelView.usualsRow`). Every entry MUST compose against the table; a unit test pins that,
    /// so a table edit can't silently orphan a starter.
    static let starters = [
        "banana",
        "energy gel",
        "sports drink",
        "greek yogurt with granola",
        "2 eggs, toast, coffee",
    ]

    // MARK: The table

    /// One food: how it displays, its natural unit (the estimator's own unit vocabulary — "gel",
    /// "egg", "slice", "cup"), and per-ONE-unit nutrition. Micros (K/Mg/Fe/Ca) default to 0 —
    /// genuinely negligible for water, gels, jam — and carry USDA-ish middles where they matter.
    private struct Entry {
        let name: String
        let unit: String
        let kcal: Int
        let carbsG: Int
        let proteinG: Int
        let fatG: Int
        let sodiumMg: Int
        var fluidsMl: Int = 0
        var kMg: Int = 0
        var mgMg: Int = 0
        var feMg: Double = 0
        var caMg: Int = 0
        // Quality signals (2026-08-15): grams of fiber / total sugars / saturated fat per unit,
        // and the NOVA class. Defaults: zeros + NOVA 1 (right for water/coffee/produce; every
        // processed entry sets its own).
        var fiber: Int = 0
        var sugar: Int = 0
        var satFat: Int = 0
        var nova: Int = 1
    }

    /// (aliases, entry) — aliases are written in POST-`MealTextKey`-normalization form: lowercase,
    /// fillers dropped ("glass of milk" arrives as "glass milk"), hyphens spaced ("peanut-butter"
    /// arrives as "peanut butter"), number words already digits. Plurals are explicit rows.
    private static let entries: [(keys: [String], entry: Entry)] = [
        // — Sports nutrition (the mid-run/race vocabulary; the reason this table exists) —
        // Gel/chew micros stay 0: they vary wildly by brand, and under-reporting beats fabricating.
        (["gel", "gels", "energy gel", "energy gels"],
         Entry(name: "Energy Gel", unit: "gel", kcal: 100, carbsG: 23, proteinG: 0, fatG: 0, sodiumMg: 45,
               sugar: 11, nova: 4)),                                                                                // typical 32 g gel
        (["chews", "energy chews", "chew"],
         Entry(name: "Energy Chews", unit: "serving", kcal: 100, carbsG: 24, proteinG: 0, fatG: 0, sodiumMg: 50,
               sugar: 17, nova: 4)),                                                                                // per packet-half serving
        (["energy bar", "energy bars"],
         Entry(name: "Energy Bar", unit: "bar", kcal: 230, carbsG: 45, proteinG: 9, fatG: 6, sodiumMg: 190,
               kMg: 200, mgMg: 60, feMg: 1.4, caMg: 40, fiber: 4, sugar: 20, satFat: 1, nova: 4)),                  // oat-based 68 g bar
        (["sports drink", "sports drinks", "electrolyte drink"],
         Entry(name: "Sports Drink", unit: "bottle", kcal: 130, carbsG: 34, proteinG: 0, fatG: 0, sodiumMg: 230,
               fluidsMl: 500, kMg: 60, sugar: 34, nova: 4)),                                                        // 500 ml bottle
        (["water", "glass water"],
         Entry(name: "Water", unit: "glass", kcal: 0, carbsG: 0, proteinG: 0, fatG: 0, sodiumMg: 0, fluidsMl: 250)),
        (["electrolytes", "electrolyte tab", "electrolyte tabs", "salt tab", "salt tabs"],
         Entry(name: "Electrolyte Tab", unit: "tab", kcal: 10, carbsG: 2, proteinG: 0, fatG: 0, sodiumMg: 300,
               kMg: 200, mgMg: 60, caMg: 60, sugar: 2, nova: 4)),
        (["banana", "bananas"],
         Entry(name: "Banana", unit: "banana", kcal: 105, carbsG: 27, proteinG: 1, fatG: 0, sodiumMg: 1,
               kMg: 422, mgMg: 32, feMg: 0.3, caMg: 6, fiber: 3, sugar: 14)),                                       // medium
        (["date", "dates"],
         Entry(name: "Dates", unit: "date", kcal: 66, carbsG: 18, proteinG: 0, fatG: 0, sodiumMg: 0,
               kMg: 167, mgMg: 13, feMg: 0.2, caMg: 15, fiber: 2, sugar: 16)),                                      // medjool
        (["chocolate milk"],
         Entry(name: "Chocolate Milk", unit: "cup", kcal: 208, carbsG: 26, proteinG: 8, fatG: 8, sodiumMg: 150,
               fluidsMl: 250, kMg: 420, mgMg: 33, feMg: 0.4, caMg: 280, sugar: 24, satFat: 5, nova: 3)),            // the classic recovery cup

        // — Breakfast staples (the "2 eggs, toast, coffee" vocabulary) —
        (["egg", "eggs"],
         Entry(name: "Egg", unit: "egg", kcal: 72, carbsG: 0, proteinG: 6, fatG: 5, sodiumMg: 71,
               kMg: 69, mgMg: 6, feMg: 0.9, caMg: 28, satFat: 2)),                                                  // large
        (["toast", "slice toast", "slices toast"],
         Entry(name: "Toast", unit: "slice", kcal: 75, carbsG: 13, proteinG: 3, fatG: 1, sodiumMg: 135,
               kMg: 37, mgMg: 13, feMg: 1.0, caMg: 38, fiber: 1, sugar: 1, nova: 3)),                               // 30 g slice, enriched
        (["bread", "slice bread", "slices bread"],
         Entry(name: "Bread", unit: "slice", kcal: 75, carbsG: 13, proteinG: 3, fatG: 1, sodiumMg: 135,
               kMg: 37, mgMg: 13, feMg: 1.0, caMg: 38, fiber: 1, sugar: 1, nova: 3)),
        (["bagel", "bagels"],
         Entry(name: "Bagel", unit: "bagel", kcal: 245, carbsG: 48, proteinG: 10, fatG: 2, sodiumMg: 430,
               kMg: 105, mgMg: 26, feMg: 2.8, caMg: 20, fiber: 2, sugar: 5, nova: 3)),                              // plain, 95 g, enriched
        (["butter"],
         Entry(name: "Butter", unit: "tbsp", kcal: 102, carbsG: 0, proteinG: 0, fatG: 12, sodiumMg: 91,
               satFat: 7, nova: 2)),
        (["peanut butter"],
         Entry(name: "Peanut Butter", unit: "tbsp", kcal: 95, carbsG: 4, proteinG: 4, fatG: 8, sodiumMg: 70,
               kMg: 104, mgMg: 27, feMg: 0.3, caMg: 8, fiber: 1, sugar: 2, satFat: 2, nova: 3)),
        (["jam", "jelly"],
         Entry(name: "Jam", unit: "tbsp", kcal: 56, carbsG: 14, proteinG: 0, fatG: 0, sodiumMg: 8,
               sugar: 10, nova: 3)),
        (["honey"],
         Entry(name: "Honey", unit: "tbsp", kcal: 64, carbsG: 17, proteinG: 0, fatG: 0, sodiumMg: 1,
               sugar: 17, nova: 2)),
        (["oatmeal", "oats", "porridge", "bowl oatmeal", "bowl oats"],
         Entry(name: "Oatmeal", unit: "bowl", kcal: 150, carbsG: 27, proteinG: 5, fatG: 3, sodiumMg: 5,
               kMg: 143, mgMg: 55, feMg: 1.7, caMg: 20, fiber: 4, sugar: 1, satFat: 1)),                            // 40 g dry, water-cooked
        (["greek yogurt", "greek yoghurt", "yogurt", "yoghurt"],
         Entry(name: "Greek Yogurt", unit: "cup", kcal: 150, carbsG: 9, proteinG: 20, fatG: 4, sodiumMg: 65,
               kMg: 240, mgMg: 17, feMg: 0.1, caMg: 230, sugar: 9, satFat: 2)),                                     // plain low-fat cup
        (["granola"],
         Entry(name: "Granola", unit: "serving", kcal: 210, carbsG: 32, proteinG: 5, fatG: 7, sodiumMg: 15,
               kMg: 150, mgMg: 50, feMg: 1.5, caMg: 30, fiber: 4, sugar: 12, satFat: 1, nova: 3)),                  // ½ cup
        (["berries", "blueberries", "strawberries"],
         Entry(name: "Berries", unit: "cup", kcal: 65, carbsG: 16, proteinG: 1, fatG: 0, sodiumMg: 2,
               kMg: 110, mgMg: 9, feMg: 0.4, caMg: 9, fiber: 4, sugar: 10)),
        (["coffee", "black coffee", "cup coffee"],
         Entry(name: "Coffee", unit: "cup", kcal: 2, carbsG: 0, proteinG: 0, fatG: 0, sodiumMg: 5,
               fluidsMl: 240, kMg: 116, mgMg: 7, caMg: 5)),
        (["espresso"],
         Entry(name: "Espresso", unit: "shot", kcal: 3, carbsG: 0, proteinG: 0, fatG: 0, sodiumMg: 2,
               fluidsMl: 30, kMg: 34, mgMg: 2, caMg: 1)),
        (["tea", "cup tea", "green tea"],
         Entry(name: "Tea", unit: "cup", kcal: 2, carbsG: 0, proteinG: 0, fatG: 0, sodiumMg: 3,
               fluidsMl: 240, kMg: 88)),
        (["milk", "glass milk", "cup milk"],
         Entry(name: "Milk", unit: "cup", kcal: 122, carbsG: 12, proteinG: 8, fatG: 5, sodiumMg: 95,
               fluidsMl: 244, kMg: 342, mgMg: 27, caMg: 293, sugar: 12, satFat: 3)),                                // 2%
        (["orange juice", "oj"],
         Entry(name: "Orange Juice", unit: "cup", kcal: 110, carbsG: 26, proteinG: 2, fatG: 0, sodiumMg: 2,
               fluidsMl: 248, kMg: 496, mgMg: 27, feMg: 0.5, caMg: 27, sugar: 21, nova: 2)),
        (["rice cake", "rice cakes"],
         Entry(name: "Rice Cake", unit: "cake", kcal: 35, carbsG: 7, proteinG: 1, fatG: 0, sodiumMg: 15,
               kMg: 26, mgMg: 12, feMg: 0.3, caMg: 1, nova: 3)),
        // Every spelling dictation produces for the mid-ride classic; label numbers (22 g bar).
        (["rice krispie treat", "rice krispie treats", "rice krispy treat", "rice krispy treats",
          "rice crispy treat", "rice crispy treats", "rice crispie treat", "rice crispie treats",
          "krispie treat", "krispie treats", "crispy treat", "crispy treats"],
         Entry(name: "Rice Krispie Treat", unit: "bar", kcal: 90, carbsG: 17, proteinG: 1, fatG: 2,
               sodiumMg: 105, sugar: 8, satFat: 1, nova: 4)),

        // — Breakfast plates & bakery (countable, standard-portion) —
        (["pancake", "pancakes"],
         Entry(name: "Pancake", unit: "pancake", kcal: 90, carbsG: 15, proteinG: 3, fatG: 2, sodiumMg: 160,
               kMg: 50, feMg: 0.7, caMg: 40, fiber: 1, sugar: 3, satFat: 1, nova: 3)),                              // 4-inch
        (["waffle", "waffles"],
         Entry(name: "Waffle", unit: "waffle", kcal: 220, carbsG: 25, proteinG: 6, fatG: 11, sodiumMg: 380,
               kMg: 120, mgMg: 14, feMg: 1.7, caMg: 100, fiber: 1, sugar: 2, satFat: 2, nova: 3)),                  // 7-inch round
        (["tortilla", "tortillas", "flour tortilla", "flour tortillas"],
         Entry(name: "Tortilla", unit: "tortilla", kcal: 140, carbsG: 24, proteinG: 4, fatG: 4, sodiumMg: 330,
               kMg: 60, mgMg: 10, feMg: 1.1, caMg: 60, fiber: 1, sugar: 1, satFat: 1, nova: 3)),                    // 8-inch flour
        (["croissant", "croissants"],
         Entry(name: "Croissant", unit: "croissant", kcal: 235, carbsG: 26, proteinG: 5, fatG: 12, sodiumMg: 265,
               kMg: 70, feMg: 1.2, caMg: 20, fiber: 1, sugar: 6, satFat: 7, nova: 3)),
        (["muffin", "muffins", "blueberry muffin"],
         Entry(name: "Muffin", unit: "muffin", kcal: 380, carbsG: 55, proteinG: 6, fatG: 15, sodiumMg: 340,
               kMg: 90, feMg: 1.5, caMg: 30, fiber: 1, sugar: 30, satFat: 3, nova: 4)),                             // bakery-size
        (["donut", "donuts", "doughnut", "doughnuts"],
         Entry(name: "Donut", unit: "donut", kcal: 260, carbsG: 31, proteinG: 3, fatG: 14, sodiumMg: 130,
               kMg: 60, feMg: 1.2, fiber: 1, sugar: 12, satFat: 6, nova: 4)),                                       // glazed
        (["cookie", "cookies", "chocolate chip cookie", "chocolate chip cookies"],
         Entry(name: "Cookie", unit: "cookie", kcal: 160, carbsG: 22, proteinG: 2, fatG: 8, sodiumMg: 110,
               kMg: 50, feMg: 0.8, fiber: 1, sugar: 13, satFat: 3, nova: 4)),                                       // medium choc-chip

        // — Lunch/dinner countables —
        (["chicken breast", "chicken breasts", "grilled chicken breast"],
         Entry(name: "Chicken Breast", unit: "breast", kcal: 200, carbsG: 0, proteinG: 38, fatG: 4, sodiumMg: 90,
               kMg: 300, mgMg: 33, feMg: 0.9, caMg: 10, satFat: 1)),                                                // cooked, ~120 g
        (["slice pizza", "slices pizza", "pizza slice", "pizza slices"],
         Entry(name: "Pizza", unit: "slice", kcal: 285, carbsG: 36, proteinG: 12, fatG: 10, sodiumMg: 640,
               kMg: 184, mgMg: 20, feMg: 2.5, caMg: 220, fiber: 2, sugar: 4, satFat: 5, nova: 3)),                  // cheese, ⅛ of 14"
        (["soda", "coke", "cola", "can soda", "can coke", "soda can"],
         Entry(name: "Soda", unit: "can", kcal: 140, carbsG: 39, proteinG: 0, fatG: 0, sodiumMg: 45,
               fluidsMl: 355, sugar: 39, nova: 4)),                                                                 // 355 ml can

        // — Recovery / snacks (countable, label-stable) —
        (["protein shake", "whey", "whey protein", "recovery shake"],
         Entry(name: "Protein Shake", unit: "serving", kcal: 120, carbsG: 3, proteinG: 24, fatG: 1, sodiumMg: 50,
               fluidsMl: 300, kMg: 150, mgMg: 30, feMg: 0.5, caMg: 120, sugar: 2, satFat: 1, nova: 4)),             // 1 scoop + water
        (["protein bar", "protein bars"],
         Entry(name: "Protein Bar", unit: "bar", kcal: 210, carbsG: 22, proteinG: 20, fatG: 7, sodiumMg: 200,
               kMg: 180, mgMg: 40, feMg: 1.5, caMg: 150, fiber: 3, sugar: 12, satFat: 3, nova: 4)),
        (["apple", "apples"],
         Entry(name: "Apple", unit: "apple", kcal: 95, carbsG: 25, proteinG: 0, fatG: 0, sodiumMg: 2,
               kMg: 195, mgMg: 9, feMg: 0.2, caMg: 11, fiber: 4, sugar: 19)),                                       // medium
        (["orange", "oranges"],
         Entry(name: "Orange", unit: "orange", kcal: 62, carbsG: 15, proteinG: 1, fatG: 0, sodiumMg: 0,
               kMg: 237, mgMg: 13, feMg: 0.1, caMg: 52, fiber: 3, sugar: 12)),
        (["avocado"],
         Entry(name: "Avocado", unit: "avocado", kcal: 240, carbsG: 12, proteinG: 3, fatG: 22, sodiumMg: 10,
               kMg: 975, mgMg: 58, feMg: 1.1, caMg: 24, fiber: 10, sugar: 1, satFat: 3)),                           // whole
        (["almonds", "nuts", "handful nuts", "handful almonds"],
         Entry(name: "Almonds", unit: "handful", kcal: 165, carbsG: 6, proteinG: 6, fatG: 14, sodiumMg: 0,
               kMg: 208, mgMg: 77, feMg: 1.0, caMg: 76, fiber: 4, sugar: 1, satFat: 1)),                            // 28 g
        (["cheese", "slice cheese"],
         Entry(name: "Cheese", unit: "slice", kcal: 113, carbsG: 0, proteinG: 7, fatG: 9, sodiumMg: 180,
               kMg: 21, mgMg: 8, feMg: 0.1, caMg: 200, satFat: 5, nova: 3)),                                        // 28 g cheddar
        (["dark chocolate"],
         Entry(name: "Dark Chocolate", unit: "serving", kcal: 110, carbsG: 9, proteinG: 1, fatG: 8, sodiumMg: 5,
               kMg: 145, mgMg: 46, feMg: 2.4, caMg: 15, fiber: 2, sugar: 5, satFat: 5, nova: 3)),                   // 20 g / 2 squares
    ]

    /// alias → entry, flattened once. A duplicate alias would be a curation bug — first one wins,
    /// and the `noDuplicateAliases` test keeps the table honest.
    private static let table: [String: Entry] = {
        var t: [String: Entry] = [:]
        for (keys, entry) in entries {
            for key in keys where t[key] == nil { t[key] = entry }
        }
        return t
    }()

    #if DEBUG
    /// Test hook: every alias, so the duplicate-detection test can compare counts.
    static var aliasCount: Int { entries.reduce(0) { $0 + $1.keys.count } }
    static var uniqueAliasCount: Int { table.count }
    #endif

    // MARK: Compose

    /// The whole meal, or nil. ALL food phrases must resolve — one stranger and the AI takes over.
    static func compose(_ raw: String) -> [Item]? {
        let segments = MealTextKey.segments(raw)
        guard !segments.isEmpty else { return nil }
        var items: [Item] = []
        for segment in segments {
            guard let item = item(for: segment) else { return nil }
            items.append(item)
        }
        return items
    }

    /// One food phrase → one item. "2 eggs" → qty 2 of the egg entry; a bare "banana" is qty 1.
    static func item(for segment: String) -> Item? {
        var tokens = segment.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        var qty = 1.0
        if let q = quantity(tokens[0]) {
            qty = q
            tokens.removeFirst()
        }
        // 0.25–99: below is a typo, above is absurd — both decline to the AI rather than guess.
        guard qty >= 0.25, qty <= 99 else { return nil }
        guard let e = table[tokens.joined(separator: " ")] else { return nil }
        return Item(name: e.name, qty: qty, unit: e.unit,
                    kcal: scaled(e.kcal, qty), carbsG: scaled(e.carbsG, qty),
                    proteinG: scaled(e.proteinG, qty), fatG: scaled(e.fatG, qty),
                    sodiumMg: scaled(e.sodiumMg, qty), fluidsMl: scaled(e.fluidsMl, qty),
                    potassiumMg: scaled(e.kMg, qty), magnesiumMg: scaled(e.mgMg, qty),
                    ironMg: (e.feMg * qty * 10).rounded() / 10,   // one decimal, like MealItem.scaled
                    calciumMg: scaled(e.caMg, qty),
                    fiberG: scaled(e.fiber, qty), sugarG: scaled(e.sugar, qty),
                    satFatG: scaled(e.satFat, qty), nova: e.nova)   // class describes the food, not the amount
    }

    /// A leading count: "2", "1.5", "0.5" — and proper "/" fractions only ("1/2", "3/4").
    /// A ":" number ("2:1 carb drink") is a RATIO, not a count, and `MealTextKey` welds it into
    /// the food text, where no table key will ever match — the AI reads those.
    private static func quantity(_ token: String) -> Double? {
        if let d = Double(token) { return d }
        let parts = token.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]),
           d >= 2, d <= 8, n > 0, n < d {
            return n / d
        }
        return nil
    }

    private static func scaled(_ perUnit: Int, _ qty: Double) -> Int {
        Int((Double(perUnit) * qty).rounded())
    }
}
