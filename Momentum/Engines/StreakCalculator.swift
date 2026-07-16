import Foundation

/// Shame-free streak (PRD §21). A day "counts" if a qualifying workout completed that local day
/// **or** it's a planned rest day. The streak **resets only after 2 consecutive non-counting
/// days** — one slipped day is forgiven. Never surfaced as a punitive "streak lost."
///
/// Pure and calendar-agnostic: days are integer local-day keys (e.g. days since reference).
/// `Workout`/calendar mapping is done by the caller via `localDay(_:calendar:)`.
enum StreakCalculator {

    /// Floors that make a *workout* qualify a day (PRD §21).
    static let cardioFloorMeters = 800.0
    static let activeFloorSeconds = 300.0

    static func workoutQualifies(type: WorkoutType, distanceM: Double, activeSeconds: Double) -> Bool {
        if type.isGPS { return distanceM >= cardioFloorMeters || activeSeconds >= activeFloorSeconds }
        return activeSeconds >= activeFloorSeconds
    }

    /// Current streak ending at `today`. Walks backward counting counting-days, tolerating a
    /// single forgiven gap; two consecutive non-counting days end it.
    ///
    /// An empty `today` is *pending*, not missed — the day isn't over. Without this, an athlete
    /// whose single grace day was yesterday watches the streak hit 0 at midnight and pop back
    /// when they train that afternoon (exactly the punitive flicker PRD §21 forbids).
    static func currentStreak(countingDays: Set<Int>, today: Int) -> Int {
        guard let earliest = countingDays.min() else { return 0 }
        var streak = 0
        var misses = 0
        var day = countingDays.contains(today) ? today : today - 1
        while day >= earliest - 1 {
            if countingDays.contains(day) {
                streak += 1
                misses = 0
            } else {
                misses += 1
                if misses >= 2 { break }
            }
            day -= 1
        }
        return streak
    }

    /// Longest streak ever, applying the same 2-day-grace rule across the full range.
    static func longestStreak(countingDays: Set<Int>) -> Int {
        guard let lo = countingDays.min(), let hi = countingDays.max() else { return 0 }
        var best = 0, run = 0, misses = 0
        for day in lo...hi {
            if countingDays.contains(day) {
                run += 1
                misses = 0
                best = max(best, run)
            } else {
                misses += 1
                if misses >= 2 { run = 0 } // forgiven single gap keeps the run alive
            }
        }
        return best
    }

    /// Planned rest days — the documented other half of "a day counts": any day inside the plan's
    /// active span with no session scheduled. An athlete resting exactly when the plan says rest
    /// must never lose the streak — a 4-day/week plan has back-to-back rest days every single week.
    ///
    /// The span is first session through `min(today, last session)`: while the plan is live its
    /// gaps are prescribed rest, but once the final session passes nothing is prescribing rest
    /// anymore — without the cap, a finished/abandoned plan feeds the streak a free "rest day"
    /// every day forever and the flame climbs on total inactivity.
    static func plannedRestDays(sessionDays: Set<Int>, today: Int) -> Set<Int> {
        guard let start = sessionDays.min(), let last = sessionDays.max(), start <= today else { return [] }
        let end = min(today, last)
        guard start <= end else { return [] }
        var rest = Set<Int>()
        for day in start...end where !sessionDays.contains(day) { rest.insert(day) }
        return rest
    }

    /// Weeks meeting `daysPerWeek`, bucketed by 7-day blocks from the reference epoch.
    static func weeksActive(countingDays: Set<Int>, daysPerWeek: Int) -> Int {
        guard daysPerWeek > 0 else { return 0 }
        var perWeek: [Int: Int] = [:]
        for day in countingDays {
            perWeek[Int(floor(Double(day) / 7)), default: 0] += 1
        }
        return perWeek.values.filter { $0 >= daysPerWeek }.count
    }

    /// Map a date to an integer local-day key (a gap-free day ordinal, in `calendar`'s zone).
    /// Uses the calendar's day-in-era ordinal so every local day gets one unique, monotonic key
    /// in every timezone — flooring a UTC-anchored interval by a *local* start-of-day collides or
    /// skips a key at DST transitions in UTC±0 zones (London/Dublin/Lisbon). All comparisons are
    /// relative, so the constant offset is harmless.
    static func localDay(_ date: Date, calendar: Calendar = .current) -> Int {
        return calendar.ordinality(of: .day, in: .era, for: date) ?? 0
    }
}
