import SwiftUI

/// The Fuel metric palette (user call 2026-07-16: "give each macro and micro a color") — the
/// Health-domain doctrine's two-step applied to fueling: these are INK-grade colors (validated
/// lightness band, legible on the light surface and the dark charcoal), never raw pastels. A ring
/// wears its metric's ink while filling and turns iridescent exactly when the floor is met —
/// color is the journey, iridescence stays the earned arrival. Deliberate doctrine exception:
/// journal numbers wear their metric's ink too, binding the rows to the rings above.
extension Theme {
    enum Fuel {
        static let carbs = Color(hex: "C29013")      // amber — carbs are gold
        static let protein = Color(hex: "1E90C0")    // ice
        static let fat = Color(hex: "C96F3B")        // peach
        static let sodium = Color(hex: "9A5BD6")     // lilac
        static let potassium = Color(hex: "5B6BD6")  // periwinkle
        static let magnesium = Color(hex: "2E9E6B")  // mint
        static let iron = Color(hex: "5E7387")       // steel (the metal reads itself)
        static let calcium = Color(hex: "14929B")    // teal
    }
}

// MARK: - Colored journal lines (Text concatenation keeps them ONE accessibility element,
// so UI-test predicates and VoiceOver read the full line exactly as before)

extension Meal {
    private func sep() -> Text { Text(" · ").foregroundColor(Theme.inkTertiary) }

    /// "≈150 g carbs · 685 kcal · 49 g protein · 9 g fat · 564 mg sodium" — each metric in its
    /// ring's ink; energy stays neutral (it's the headline number, not a ring).
    var journalNumbersText: Text? {
        guard let carbs = carbsG else { return nil }
        var t = Text("≈\(carbs) g carbs").foregroundColor(Theme.Fuel.carbs)
        if let kcal { t = t + sep() + Text("\(kcal) kcal").foregroundColor(Theme.inkSecondary) }
        if let p = proteinG { t = t + sep() + Text("\(p) g protein").foregroundColor(Theme.Fuel.protein) }
        if let f = fatG { t = t + sep() + Text("\(f) g fat").foregroundColor(Theme.Fuel.fat) }
        if let s = sodiumMg { t = t + sep() + Text("\(s) mg sodium").foregroundColor(Theme.Fuel.sodium) }
        return t
    }

    /// "K 846 · Mg 101 · Fe 3.2 · Ca 52" — the micros as element symbols (the rings above teach
    /// the color → metric binding). nil until an estimate carried any.
    var journalMicrosText: Text? {
        var parts: [Text] = []
        if let k = potassiumMg, k > 0 { parts.append(Text("K \(k)").foregroundColor(Theme.Fuel.potassium)) }
        if let m = magnesiumMg, m > 0 { parts.append(Text("Mg \(m)").foregroundColor(Theme.Fuel.magnesium)) }
        if let fe = ironMg, fe > 0 {
            parts.append(Text("Fe \(fe.formatted(.number.precision(.fractionLength(0...1))))")
                .foregroundColor(Theme.Fuel.iron))
        }
        if let ca = calciumMg, ca > 0 { parts.append(Text("Ca \(ca)").foregroundColor(Theme.Fuel.calcium)) }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + sep() + $1 }
    }
}
