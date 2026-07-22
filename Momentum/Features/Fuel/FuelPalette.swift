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
        // Micros get no daily RINGS (user call 2026-07-16: slow-moving markers don't belong on
        // the dashboard) — but since 2026-07-22 they display in the Today card's MICROS grid
        // against sex-aware floors, and are estimated again (briefly cut 2026-07-21 while
        // nothing rendered them). Inks reserved for the day they earn color: the card's cells
        // deliberately stay monochrome for now.
        static let iron = Color(hex: "C4586B")       // garnet rose
        static let calcium = Color(hex: "2FA96C")    // spring mint
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

}
