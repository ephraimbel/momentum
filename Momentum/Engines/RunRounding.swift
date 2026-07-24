import Foundation

/// Clean prescription distances — a coach says "run 3.5 miles" or "a 5K", never "run 3.73 miles".
/// Storage stays SI (meters); this snaps a raw computed target to the value a coach would actually
/// write on the plan, in the athlete's own unit. Unit-aware because 6000 m is a clean 6 km but an
/// ugly 3.73 mi — both athletes deserve round numbers.
///
/// Rules, tuned to read like a real training plan:
///  • the **race session** is the race itself — snapped to the canonical distance (5K, 10K, half,
///    marathon, 50K), so it reads as "5K" / "13.1 mi" rather than a rounded-off approximation;
///  • typical runs snap to **half-unit** granularity (2, 3.5, 4, 5.5 mi · 4, 6.5, 8 km);
///  • long runs (≥ 10 units) snap to **whole units** — milestones read cleanly ("16 mi", "20 km").
enum RunRounding {

    /// Canonical race distances (m) — a race session lands exactly on one of these.
    private static let raceDistancesM: [Double] = [5_000, 10_000, 21_097.5, 42_195, 50_000]

    /// Snap a target distance (m) to the clean value a coach would prescribe, in `unit`.
    /// `isRace` forces the nearest canonical race distance (the goal is the goal, not a round number).
    static func snap(meters: Double, unit: DistanceUnit, isRace: Bool = false) -> Double {
        guard meters.isFinite, meters > 0 else { return meters }
        if isRace {
            return raceDistancesM.min { abs($0 - meters) < abs($1 - meters) } ?? meters
        }
        let perUnit = unit.resolved() == .imperial ? Formatters.metersPerMile : 1_000.0
        let value = meters / perUnit                                   // miles or km
        let increment = value >= 10 ? 1.0 : 0.5                        // whole units for long-run milestones
        let snapped = max(increment, (value / increment).rounded() * increment)
        return snapped * perUnit
    }

    /// Clean prescription paces — a coach writes "8:30/mi", never "8:24/mi". Snaps a raw engine
    /// pace (stored s/km) to a clean boundary in the athlete's own display unit, because clean is
    /// unit-relative: 5:15/km is an ugly 8:27/mi and vice versa.
    ///
    /// Granularity follows how real the precision is:
    ///  • **easy-family** paces (easy, long, recovery, free, strides) snap to **:15** — an easy
    ///    pace is a feel with a number on it, and 8:30 reads like a coach where 8:24 reads like a
    ///    spreadsheet;
    ///  • **quality + race** paces snap to **:05** — tempo/interval/race targets are real
    ///    prescriptions where a 15-second grid would blur distinct zones together.
    /// The result converts back to s/km for storage (SI everywhere; snapping is a display-unit
    /// decision made once, at prescription time).
    static func snapPace(sPerKm: Double, unit: DistanceUnit, type: RunType) -> Double {
        guard sPerKm.isFinite, sPerKm > 0 else { return sPerKm }
        let unitFactor = unit.resolved() == .imperial ? Formatters.metersPerMile / 1_000.0 : 1.0
        let incrementS = type.isQuality ? 5.0 : 15.0   // .race is quality — 5s precision
        let secPerUnit = sPerKm * unitFactor
        let snapped = max(incrementS, (secPerUnit / incrementS).rounded() * incrementS)
        // Never snap through the engine's global pace floor (2:00/km, DanielsPaces).
        return max(120, snapped / unitFactor)
    }
}
