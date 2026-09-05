import Foundation

enum HydrationInput {
    /// Only entirely recognized water phrases use this shortcut; mixed meals stay meals.
    static func milliliters(in text: String) -> Int? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let water = #"(?:plain |tap |bottled |sparkling |mineral |still )?water"#
        let quantity = #"([0-9]+(?:\.[0-9]+)?)\s*(ml|milliliters?|millilitres?|l|liters?|litres?)"#
        for pattern in ["^\(quantity) (?:of )?\(water)$", "^\(water)(?:,\\s*| )\(quantity)$"] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
                  let numberRange = Range(match.range(at: 1), in: normalized),
                  let unitRange = Range(match.range(at: 2), in: normalized),
                  let value = Double(normalized[numberRange]) else { continue }
            let milliliters = value * (normalized[unitRange].hasPrefix("m") ? 1 : 1000)
            guard milliliters.isFinite, milliliters >= 1, milliliters <= 1_000_000 else { return nil }
            return Int(milliliters.rounded())
        }
        if normalized.range(of: "^\(water)$", options: .regularExpression) != nil { return 250 }
        guard let foods = FoodStaples.compose(text), !foods.isEmpty,
              foods.allSatisfy({ $0.name == "Water" && $0.kcal == 0 }) else { return nil }
        let amount = foods.map(\.fluidsMl).reduce(0, +)
        return amount > 0 ? amount : nil
    }
}
