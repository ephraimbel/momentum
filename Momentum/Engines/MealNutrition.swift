import Foundation

/// Shared field contract for manual entry, portions, daily totals, and export.
/// Missing values stay missing; zero means the athlete or label supplied a real zero.
enum Nutrient: String, CaseIterable, Codable, Identifiable, Sendable {
    case kcal, carbs, protein, fat, fiber, sugar, saturatedFat
    case sodium, potassium, magnesium, iron, calcium, fluids

    var id: String { rawValue }
    var label: String {
        switch self {
        case .kcal: "Energy"
        case .carbs: "Carbs"
        case .protein: "Protein"
        case .fat: "Fat"
        case .fiber: "Fiber"
        case .sugar: "Sugars"
        case .saturatedFat: "Saturated fat"
        case .sodium: "Sodium"
        case .potassium: "Potassium"
        case .magnesium: "Magnesium"
        case .iron: "Iron"
        case .calcium: "Calcium"
        case .fluids: "Fluids"
        }
    }
    var unit: String {
        switch self {
        case .kcal: "kcal"
        case .sodium, .potassium, .magnesium, .iron, .calcium: "mg"
        case .fluids: "ml"
        default: "g"
        }
    }
    var precision: Int { 2 }
}

struct NutritionValues: Codable, Equatable, Sendable {
    var values: [Nutrient: Double] = [:]

    subscript(_ nutrient: Nutrient) -> Double? {
        get { values[nutrient] }
        set { values[nutrient] = newValue }
    }

    static func sum(_ rows: [NutritionValues]) -> NutritionValues {
        var result = NutritionValues()
        for field in Nutrient.allCases {
            let known = rows.compactMap { $0[field] }.filter { $0.isFinite && $0 >= 0 }
            result[field] = known.isEmpty ? nil : known.reduce(0, +)
        }
        return result
    }

    func integer(_ field: Nutrient) -> Int? {
        self[field].flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil }
    }
}

/// Text stays a draft until validation succeeds. Blank never silently becomes zero,
/// and malformed, negative, non-finite, or overflowing input never erases a saved value.
struct NutritionEntry: Equatable {
    var fields: [Nutrient: String] = [:]

    init(_ values: NutritionValues = .init()) {
        for field in Nutrient.allCases {
            if let value = values[field] { fields[field] = Self.text(value, field: field) }
        }
    }

    static func text(_ value: Double, field: Nutrient) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...field.precision)))
    }

    func parsed(locale: Locale = .current) -> (values: NutritionValues, error: String?) {
        var result = NutritionValues()
        let separator = locale.decimalSeparator ?? "."
        for field in Nutrient.allCases {
            let raw = (fields[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let normalized = raw.replacingOccurrences(of: separator, with: ".")
            // Grouping and exponents are deliberately rejected, never ambiguously reinterpreted.
            guard normalized.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let value = Double(normalized), value.isFinite, value <= 1_000_000 else {
                return (result, "Enter a non-negative number for \(field.label.lowercased()), up to 1,000,000 \(field.unit).")
            }
            result[field] = (value * 100).rounded() / 100
        }
        // Fiber is declared separately from carbohydrate on some labels (EU 1169/2011,
        // Annex I); it cannot be universally validated as a subset of the entered carbs.
        for (part, whole) in [(Nutrient.sugar, Nutrient.carbs), (.saturatedFat, .fat)] {
            if let p = result[part], let w = result[whole], p > w {
                return (result, "\(part.label) cannot be greater than \(whole.label.lowercased()). Check the label amounts.")
            }
        }
        return (result, nil)
    }
}

/// Coverage is counted per food (or one manually entered meal), not inferred from its calories.
/// A known subtotal is useful, but never presented as a complete nutrient total.
struct NutritionCoverage: Equatable {
    let total: Double?
    let known: Int
    let count: Int
    var isComplete: Bool { count > 0 && known == count }

    static func summarize(_ rows: [NutritionValues], field: Nutrient) -> NutritionCoverage {
        let values = rows.compactMap { $0[field] }.filter { $0.isFinite && $0 >= 0 }
        return .init(total: values.isEmpty ? nil : values.reduce(0, +), known: values.count, count: rows.count)
    }
}

/// Stable unrounded basis survives save/reopen; repeated +/− edits cannot create calories.
struct MealPortionBasis: Codable, Equatable, Sendable {
    var quantity: Double
    var nutrition: NutritionValues
}
