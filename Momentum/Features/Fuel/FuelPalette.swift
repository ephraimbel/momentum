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

        /// The health-score band inks (2026-08-15) — same INK-grade discipline as the metric
        /// colors above, and deliberately drawn from the same validated family: mint for whole,
        /// honey for solid, peach for mixed, garnet for processed. Garnet is a rose, not an
        /// alarm — no red "failed" state, ever (house rule).
        static func score(_ band: HealthScore.Band) -> Color {
            switch band {
            case .whole: return Color(hex: "2FA96C")
            case .solid: return Color(hex: "D5A017")
            case .mixed: return Color(hex: "C96F3B")
            case .processed: return Color(hex: "C4586B")
            }
        }
    }
}

// MARK: - Meal → HealthScore facts (the SwiftData↔engine bridge, so the engine stays pure)

extension MealItem {
    /// This item's facts at its CURRENT portion — what the deterministic `HealthScore` judges.
    var healthFacts: HealthScore.Facts {
        HealthScore.Facts(name: name, kcal: kcal, carbsG: carbsG, proteinG: proteinG, fatG: fatG,
                          sodiumMg: sodiumMg, fiberG: fiberG, sugarG: sugarG, satFatG: satFatG,
                          potassiumMg: potassiumMg, nova: nova)
    }
}

extension Meal {
    /// The meal's item facts — itemized meals judge per item; a totals-only meal (manual entry,
    /// pre-itemization history) judges as one pseudo-item from its scalar totals. One definition,
    /// so every surface (journal row, detail sheet, health page) scores a meal identically.
    var healthFacts: [HealthScore.Facts] {
        let items = self.items
        if !items.isEmpty { return items.map(\.healthFacts) }
        // Totals-only: only judge a meal that actually has numbers.
        guard let kcal, kcal > 0 || carbsG != nil else { return [] }
        return [HealthScore.Facts(name: text, kcal: kcal, carbsG: carbsG ?? 0,
                                  proteinG: proteinG ?? 0, fatG: fatG ?? 0,
                                  sodiumMg: sodiumMg ?? 0, fiberG: fiberG, sugarG: sugarG,
                                  satFatG: satFatG, potassiumMg: potassiumMg, nova: nil)]
    }

    /// The meal's health verdict, or nil while the numbers are pending. Decodes `itemsData` —
    /// hot paths (the journal rows) cache the result per refresh, exactly like `journalTitle`.
    var healthVerdict: HealthScore.Verdict? { HealthScore.aggregate(healthFacts) }
}

// MARK: - The score chip (journal rows) and gauge (detail sheet, health page)

/// The score at row size: the number in its band's ink on a soft tinted capsule. Quiet by
/// design — one glance says "82, whole-ish" without shouting at a meal.
struct HealthScoreChip: View {
    let verdict: HealthScore.Verdict

    var body: some View {
        let tint = Theme.Fuel.score(verdict.band)
        Text("\(verdict.score)")
            .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.12)))
            .contentTransition(.numericText())
            .accessibilityLabel("Health score \(verdict.score), \(verdict.band.word)")
    }
}

/// The score as a gauge — a ring drawn to score/100 in the band's ink, the numeral centered,
/// the band word beneath. A whole-food score (80+) earns iridescence: quality is progress here,
/// and the arrival is marked exactly like a fueled ring. Transform-only draw-in, Reduce Motion
/// renders complete.
struct HealthScoreGauge: View {
    let verdict: HealthScore.Verdict
    /// Ring diameter; the type scales with it (row 48 … hero 120).
    var diameter: CGFloat = 96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        let tint = Theme.Fuel.score(verdict.band)
        let earned = verdict.band == .whole
        let stroke = max(4, diameter / 14)
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Theme.hairline, lineWidth: stroke)
                Circle()
                    .trim(from: 0, to: drawn ? CGFloat(verdict.score) / 100 : 0)
                    .rotation(.degrees(-90))
                    .stroke(earned ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(tint),
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .shadow(color: (earned ? Theme.iridescent.first ?? tint : tint).opacity(0.45),
                            radius: diameter / 16)
                    .animation(Motion.lively, value: verdict.score)
                Text("\(verdict.score)")
                    .font(.display(diameter * 0.34, weight: .black)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
            }
            .frame(width: diameter, height: diameter)
            Text(verdict.band.word)
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                .foregroundStyle(tint)
        }
        .onAppear {
            if reduceMotion { drawn = true }
            else { withAnimation(Motion.pen(0.8)) { drawn = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health score")
        .accessibilityValue("\(verdict.score) out of 100, \(verdict.band.word)")
    }
}

// MARK: - Colored journal lines (Text concatenation keeps them ONE accessibility element,
// so UI-test predicates and VoiceOver read the full line exactly as before)

extension Meal {
    private func sep() -> Text { Text(" · ").foregroundColor(Theme.inkTertiary) }

    /// "≈150 g carbs · 685 kcal · 49 g protein · 9 g fat · 564 mg sodium" — each metric in its
    /// ring's ink; energy stays neutral (it's the headline number, not a ring). Present when the
    /// meal has ANY headline number (mirrors `FuelReadiness.hasNumbers`) — a kcal-only manual
    /// meal counts toward the day and must not read "Couldn't estimate" in its own row.
    var journalNumbersText: Text? {
        guard carbsG != nil || kcal != nil else { return nil }
        var pieces: [Text] = []
        if let carbs = carbsG { pieces.append(Text("≈\(carbs) g carbs").foregroundColor(Theme.Fuel.carbs)) }
        if let kcal { pieces.append(Text("\(kcal) kcal").foregroundColor(Theme.inkSecondary)) }
        if let p = proteinG { pieces.append(Text("\(p) g protein").foregroundColor(Theme.Fuel.protein)) }
        if let f = fatG { pieces.append(Text("\(f) g fat").foregroundColor(Theme.Fuel.fat)) }
        if let s = sodiumMg { pieces.append(Text("\(s) mg sodium").foregroundColor(Theme.Fuel.sodium)) }
        guard let first = pieces.first else { return nil }
        return pieces.dropFirst().reduce(first) { $0 + sep() + $1 }
    }

}
