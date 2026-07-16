import SwiftUI

/// The Fuel metric palette (user call 2026-07-16: "give each macro and micro a color") — the
/// Health-domain doctrine's two-step applied to fueling: these are INK-grade colors (validated
/// lightness band, legible on the light surface and the dark charcoal), never raw pastels. A ring
/// wears its metric's ink while filling and turns iridescent exactly when the floor is met —
/// color is the journey, iridescence stays the earned arrival. Deliberate doctrine exception:
/// journal numbers wear their metric's ink too, binding the rows to the rings above.
extension Theme {
    enum Fuel {
        static let carbs = Color(hex: "D5A017")     // honey gold
        static let protein = Color(hex: "2E8CE8")    // bright azure
        static let fat = Color(hex: "C96F3B")        // peach
        static let sodium = Color(hex: "9A5BD6")     // lilac
        static let iron = Color(hex: "C4586B")       // garnet rose — blood, never alarm-red
        static let calcium = Color(hex: "2FA96C")    // spring mint — bone-builder green
        // Collected but not displayed (trimmed 2026-07-16 — least actionable for endurance):
        static let potassium = Color(hex: "5B6BD6")  // periwinkle
        static let magnesium = Color(hex: "2E9E6B")  // mint
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

    /// "Fe 3.2 · Ca 52" — the endurance micros as element symbols (the rings above teach the
    /// color → metric binding). Potassium/magnesium are still captured in the data, just not
    /// displayed. nil until an estimate carried any.
    var journalMicrosText: Text? {
        var parts: [Text] = []
        if let fe = ironMg, fe > 0 {
            parts.append(Text("Fe \(fe.formatted(.number.precision(.fractionLength(0...1))))")
                .foregroundColor(Theme.Fuel.iron))
        }
        if let ca = calciumMg, ca > 0 { parts.append(Text("Ca \(ca)").foregroundColor(Theme.Fuel.calcium)) }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + sep() + $1 }
    }
}
