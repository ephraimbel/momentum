import Foundation

/// The deterministic food-quality judge (2026-08-15) — every health score in the app comes from
/// this one engine, computed on-device from the nutrition facts a meal already carries. The AI's
/// only contribution is label-style FACTS (sugars, fiber, saturated fat, NOVA class ride along
/// with the macros it always estimated); the JUDGMENT is pure arithmetic here, unit-tested, and
/// identical however the numbers arrived (AI, staples table, barcode label, the athlete's hand).
///
/// The model is a per-serving adaptation of nutrient-profile scoring (Nutri-Score-family), built
/// for the one representation we actually have — per-item values at the eaten portion, no gram
/// weights — so every term is an ENERGY-DENSITY term (per kcal), not a per-100 g term:
///  - drags: sugars as a share of energy (softened for whole foods, where sugar is intrinsic —
///    fruit and plain dairy), refined carbs in processed foods, saturated fat past a grace band,
///    ultra-processing (NOVA 4), and only an outsized single-item sodium load — sodium is a
///    training TARGET in this app (floors doctrine), so the electrolyte lane never gets dinged.
///  - lifts: fiber density, protein density, mineral richness (potassium as the produce/dairy
///    proxy), and whole-food processing class (NOVA 1).
///
/// Framing rules (house doctrine): the score judges the FOOD, never the athlete. Band words are
/// descriptive, not moral — "Processed", never "bad" or "unhealthy day, shame". No diet, weight,
/// or medical language. Race fuel (gels, sports drinks) reads low on purpose — sugar is its job —
/// and the day analysis says so out loud rather than pretending otherwise.
///
/// Nil-resilience: every quality field is optional. A term with no data contributes nothing —
/// meals itemized before these fields existed still score from macros + micros alone, just more
/// roughly (every number here reads ≈ anyway).
enum HealthScore {

    // MARK: Inputs

    /// One food's facts at its CURRENT portion — the pure mirror of `MealItem` (converted in the
    /// Fuel feature so the engine never touches SwiftData).
    struct Facts: Equatable, Sendable {
        var name: String = ""
        var kcal: Int = 0
        var carbsG: Int = 0
        var proteinG: Int = 0
        var fatG: Int = 0
        var sodiumMg: Int = 0
        var fiberG: Int?
        var sugarG: Int?
        var satFatG: Int?
        var potassiumMg: Int?
        /// NOVA processing class 1–4; nil = unknown (pre-field meals, manual totals).
        var nova: Int?
    }

    // MARK: Verdict

    /// Score bands — descriptive words, no shame, no red. "Processed" states what the food is;
    /// it never grades the athlete.
    enum Band: Int, CaseIterable, Sendable {
        case processed = 0, mixed, solid, whole

        var word: String {
            switch self {
            case .whole: return "Whole"
            case .solid: return "Solid"
            case .mixed: return "Mixed"
            case .processed: return "Processed"
            }
        }

        static func band(for score: Int) -> Band {
            switch score {
            case 80...: return .whole
            case 60...: return .solid
            case 40...: return .mixed
            default: return .processed
            }
        }
    }

    /// What moved a score, signed — the transparency layer ("show what's computed").
    enum DriverKind: String, CaseIterable, Sendable {
        case fiber, protein, minerals, wholeFood
        case sugars, refinedCarbs, satFat, sodium, ultraProcessed

        /// Sentence-ready lowercase phrase ("lifted by fiber and protein").
        var phrase: String {
            switch self {
            case .fiber: return "fiber"
            case .protein: return "protein"
            case .minerals: return "mineral-rich food"
            case .wholeFood: return "whole food"
            case .sugars: return "sugars"
            case .refinedCarbs: return "refined carbs"
            case .satFat: return "saturated fat"
            case .sodium: return "a heavy sodium hit"
            case .ultraProcessed: return "ultra-processed food"
            }
        }

        /// Row label for the health page ("Fiber", "Ultra-processed food").
        var label: String {
            let p = phrase
            return p.prefix(1).uppercased() + p.dropFirst()
        }
    }

    struct Driver: Equatable, Sendable {
        let kind: DriverKind
        /// Signed score points (+ lifts, − drags).
        let points: Double
    }

    struct Verdict: Equatable, Sendable {
        let score: Int          // 0–100
        let band: Band
        /// Sorted by |points|, strongest first. Only meaningful movers (|points| ≥ 1).
        let drivers: [Driver]
    }

    // MARK: One item

    /// Score one food. Deterministic; safe on degenerate inputs (kcal 0, all-nil quality fields).
    static func score(_ f: Facts) -> Verdict {
        // Near-zero energy (water, black coffee, tea): nothing to profile — judged on processing
        // alone. An ultra-processed zero-cal drink is honestly named; water reads whole.
        guard f.kcal >= 15 else {
            if (f.nova ?? 1) >= 4 {
                return Verdict(score: 35, band: .processed,
                               drivers: [Driver(kind: .ultraProcessed, points: -18)])
            }
            return Verdict(score: 92, band: .whole, drivers: [])
        }

        let kcal = Double(f.kcal)
        var total = 70.0
        var drivers: [Driver] = []
        func add(_ kind: DriverKind, _ points: Double) {
            total += points
            if abs(points) >= 1 { drivers.append(Driver(kind: kind, points: points)) }
        }

        // Sugars as a share of energy, softened where sugar is intrinsic to a whole food
        // (fruit, plain dairy): the NOVA class is the added-vs-intrinsic proxy.
        if let sugar = f.sugarG, sugar > 0 {
            let share = min(1, Double(sugar) * 4 / kcal)
            let intrinsicSoftening: Double
            switch f.nova {
            case 1: intrinsicSoftening = 0.25
            case 2: intrinsicSoftening = 0.5
            case 3: intrinsicSoftening = 0.8
            case 4: intrinsicSoftening = 1.0
            default: intrinsicSoftening = 0.6
            }
            add(.sugars, -45 * share * intrinsicSoftening)
        }
        // Refined carbs — carbs that are neither fiber nor sugars, in a processed food.
        if let nova = f.nova, nova >= 3 {
            let refined = max(0, f.carbsG - (f.fiberG ?? 0) - (f.sugarG ?? 0))
            add(.refinedCarbs, -15 * min(1, Double(refined) * 4 / kcal))
        }
        // Saturated fat past a 10%-of-energy grace band (whole foods carry a little by nature).
        if let sat = f.satFatG, sat > 0 {
            let share = Double(sat) * 9 / kcal
            add(.satFat, -20 * min(1, max(0, share - 0.10) / 0.35))
        }
        // Sodium: a training target in this app (floors, never ceilings) — only an outsized
        // single-item load registers, and the electrolyte lane (tabs, sports drinks) never trips it.
        if f.sodiumMg > 600 {
            add(.sodium, -min(12, Double(f.sodiumMg - 600) / 100))
        }
        // Fiber density: 3 g per 100 kcal is full marks (oats, fruit, legumes live here).
        if let fiber = f.fiberG, fiber > 0 {
            add(.fiber, 15 * min(1, Double(fiber) / kcal * 100 / 3))
        }
        // Protein density: 8 g per 100 kcal is full marks (yogurt, eggs, lean meat, whey).
        if f.proteinG > 0 {
            add(.protein, 10 * min(1, Double(f.proteinG) / kcal * 100 / 8))
        }
        // Mineral richness — potassium density is the honest single proxy for produce and dairy.
        if let k = f.potassiumMg, k > 0 {
            add(.minerals, 8 * min(1, Double(k) / kcal / 3))
        }
        // Processing class — the strongest single signal in the nutrition literature.
        switch f.nova {
        case 1: add(.wholeFood, 8)
        case 2: add(.wholeFood, 2)
        case 3: add(.ultraProcessed, -4)
        case 4: add(.ultraProcessed, -18)
        default: break
        }

        let score = Int(min(100, max(0, total)).rounded())
        return Verdict(score: score, band: Band.band(for: score),
                       drivers: drivers.sorted { abs($0.points) > abs($1.points) })
    }

    // MARK: A meal, a day

    /// Energy weight for aggregation — floored so zero-cal items (water at 92, a diet soda at 35)
    /// still register without ever dominating a real meal.
    private static func weight(_ f: Facts) -> Double { max(Double(f.kcal), 20) }

    /// Aggregate verdict over a set of items (one meal, or the whole day): energy-weighted mean
    /// score, drivers merged by kind with the same weights. nil when there is nothing to judge.
    static func aggregate(_ items: [Facts]) -> Verdict? {
        guard !items.isEmpty else { return nil }
        var weightedScore = 0.0
        var totalWeight = 0.0
        var byKind: [DriverKind: Double] = [:]
        for f in items {
            let v = score(f)
            let w = weight(f)
            weightedScore += Double(v.score) * w
            totalWeight += w
            for d in v.drivers { byKind[d.kind, default: 0] += d.points * w }
        }
        guard totalWeight > 0 else { return nil }
        let s = Int((weightedScore / totalWeight).rounded())
        let drivers = byKind.map { Driver(kind: $0.key, points: $0.value / totalWeight) }
            .filter { abs($0.points) >= 1 }
            .sorted { abs($0.points) > abs($1.points) }
        return Verdict(score: s, band: Band.band(for: s), drivers: drivers)
    }

    /// "Lifted by fiber and whole food. Dragged by sugars." — one deterministic sentence (or two)
    /// from a verdict's strongest movers. nil when nothing moved the score meaningfully.
    static func driversLine(_ drivers: [Driver]) -> String? {
        let lifts = drivers.filter { $0.points >= 3 }.prefix(2).map(\.kind.phrase)
        let drags = drivers.filter { $0.points <= -3 }.prefix(2).map(\.kind.phrase)
        var parts: [String] = []
        if !lifts.isEmpty { parts.append("Lifted by \(lifts.joined(separator: " and ")).") }
        if !drags.isEmpty { parts.append("Dragged by \(drags.joined(separator: " and ")).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: The day's analysis (the health page)

    struct DayAnalysis: Equatable, Sendable {
        let verdict: Verdict
        let itemCount: Int
        /// How many items landed in each band — the "type of food you ate" picture.
        let bandCounts: [Band: Int]
        /// Which foods carried each driver, strongest first (≤2 names) — the WHY behind every
        /// row: "Sugars, mostly the soda and the muffin", not just "Sugars −9".
        let driverSources: [DriverKind: [String]]
        /// Race fuel present (gels, sports drinks, chews, electrolyte tabs) — cues the honest
        /// caveat line: sports nutrition reads low BY DESIGN.
        let sportsFuelPresent: Bool
        /// Band-keyed plain-words lead. Judges the food, never the athlete.
        let headline: String
    }

    static func day(_ items: [Facts]) -> DayAnalysis? {
        guard let verdict = aggregate(items) else { return nil }
        var counts: [Band: Int] = [:]
        // Per-(driver, food) contribution, accumulated with the SAME weights as `aggregate` so
        // the attribution can never disagree with the rows it explains. Keyed by name, so two
        // gels are one "Energy Gel" that carries their combined weight.
        var contributions: [DriverKind: [String: Double]] = [:]
        for f in items {
            let v = score(f)
            counts[v.band, default: 0] += 1
            guard !f.name.isEmpty else { continue }
            let w = weight(f)
            for d in v.drivers {
                contributions[d.kind, default: [:]][f.name, default: 0] += abs(d.points) * w
            }
        }
        let sources = contributions.mapValues { byName in
            byName.sorted { $0.value > $1.value }.prefix(2).map(\.key)
        }
        let headline: String
        switch verdict.band {
        case .whole:
            headline = "Mostly whole food today. This is the eating that training compounds on."
        case .solid:
            headline = "Solid quality today. Whole foods are carrying the day."
        case .mixed:
            headline = "A mixed day. Plenty to build on, and one whole-food swap would move it."
        case .processed:
            headline = "Processed food led today. That judges the shelf, not you. One whole-food swap moves this fast."
        }
        return DayAnalysis(verdict: verdict, itemCount: items.count, bandCounts: counts,
                           driverSources: sources,
                           sportsFuelPresent: items.contains { isSportsFuel($0.name) },
                           headline: headline)
    }

    /// Race-fuel detection by pinned vocabulary — the staples table's own names plus the words
    /// the estimator reliably uses. Deliberately narrow: a miss just skips a caveat line.
    static func isSportsFuel(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["gel", "sports drink", "chews", "electrolyte", "energy drink"]
            .contains { n.contains($0) }
    }
}
