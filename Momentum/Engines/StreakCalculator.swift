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
    static func currentStreak(countingDays: Set<Int>, today: Int) -> Int {
        guard let earliest = countingDays.min() else { return 0 }
        var streak = 0
        var misses = 0
        var day = today
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
    /// active span (first session through today, never the future) with no session scheduled. An
    /// athlete resting exactly when the plan says rest must never lose the streak — a 4-day/week
    /// plan has back-to-back rest days every single week.
    static func plannedRestDays(sessionDays: Set<Int>, today: Int) -> Set<Int> {
        guard let start = sessionDays.min(), start <= today else { return [] }
        var rest = Set<Int>()
        for day in start...today where !sessionDays.contains(day) { rest.insert(day) }
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

    /// Map a date to an integer local-day key (days since 2001 reference, in `calendar`'s zone).
    static func localDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        return Int((start.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }
}
