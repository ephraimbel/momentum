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
}
