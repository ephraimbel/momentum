import Foundation

/// The one quiet fueling tip under the day readout (FUEL-FLOW §0) — deterministic, ranked rules
/// over the `FuelReadiness` readout and the clock, exactly like every other engine: no AI, no
/// randomness, unit-tested. One line or nothing — **silence is a feature**; a fueled day earns an
/// iridescent bar, not more words. Fueling language only (floors, banking, funding the work) —
/// never diet, weight, or restriction.
enum FuelTips {

    /// First matching rule wins; nil = say nothing.
    static func line(readout r: FuelReadiness.DayReadout,
                     now: Date,
                     calendar: Calendar = .current) -> String? {
        // The refuel banner owns its moment — never two voices at once.
        guard !r.refuelDue else { return nil }
        // Empty day: the headline already asks for the first log.
        guard r.status != .empty else { return nil }

        let hour = Double(calendar.component(.hour, from: now))
            + Double(calendar.component(.minute, from: now)) / 60

        // Race eve — the classic load is steady all day, not one heroic dinner.
        if r.raceEve, r.status != .fueled {
            return "Race eve — bank carbs steadily through the day, not in one late dinner."
        }
        // Morning of a session day: what you eat now is what shows up at the start.
        // (Not before 05:00 — "breakfast" advice at 3 a.m. reads like a bug, not a coach.)
        if hour >= 5, hour < 11, r.drivingIsToday, r.status != .fueled, let s = r.drivingSession {
            return "Carbs eaten early do the most for \(s) — breakfast is part of the workout."
        }
        // Long-sweat day, sodium far behind by the afternoon.
        if hour >= 12, r.sodiumFloorMg > FuelReadiness.sodiumBaselineMg, r.sodiumMg < r.sodiumFloorMg / 2 {
            return "Sweaty day — ≈\(r.sodiumFloorMg - r.sodiumMg) mg below the sodium floor. Salt your food."
        }
        // Evening protein gap → a recovery-forward dinner closes it.
        if hour >= 17, r.proteinG < r.proteinFloorG * 3 / 4 {
            return "≈\(r.proteinFloorG - r.proteinG) g of protein to go — a protein-forward dinner closes it."
        }
        // Late and still behind on carbs — dinner counts, no drama.
        if hour >= 19, r.status == .behind, r.carbsFloorG > r.carbsG {
            return "≈\(r.carbsFloorG - r.carbsG) g of carbs still to bank — dinner counts."
        }
        return nil
    }
}
