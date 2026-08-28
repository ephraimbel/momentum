import Foundation

/// The numbers behind the consistency grid (owner call 2026-08-28: the Progress page carries the
/// profile's consistency graph, and its tap goes deeper). Pure day-ordinal arithmetic over the
/// same `countingDays` / active-minutes signals the grid draws — the window is the grid's own
/// columns (`weeks` × 7 days ending on `today`), so the picture and the numbers can never disagree.
enum ConsistencyFacts {
    struct Window: Equatable {
        let weeks: Int
        let activeDays: Int           // days that qualified (`StreakCalculator.workoutQualifies`)
        let activeMinutes: Double     // Σ workout duration inside the window
        let sessions: Int             // every logged workout inside the window
        let bestWeekSessions: Int     // the busiest grid column
        var windowDays: Int { weeks * 7 }
        var sessionsPerWeek: Double { weeks > 0 ? Double(sessions) / Double(weeks) : 0 }
    }

    /// Active minutes per local day — the grid's intensity signal (a 20-minute jog and a two-hour
    /// long run are different days, and the grid says so). The profile's own formula.
    @MainActor
    static func dayMinutes(workouts: [Workout], calendar: Calendar = .current) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for w in workouts {
            out[StreakCalculator.localDay(w.startedAt, calendar: calendar), default: 0] += w.durationS / 60
        }
        return out
    }

    /// Sessions per local day.
    @MainActor
    static func sessionsByDay(workouts: [Workout], calendar: Calendar = .current) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for w in workouts {
            out[StreakCalculator.localDay(w.startedAt, calendar: calendar), default: 0] += 1
        }
        return out
    }

    /// Qualifying days inside the trailing window — the card's headline number.
    static func activeDays(countingDays: Set<Int>, weeks: Int, today: Int) -> Int {
        (0..<(weeks * 7)).filter { countingDays.contains(today - $0) }.count
    }

    /// The full read for one window. Walks the grid's cells exactly as the heatmap lays them out
    /// (column = 7 days, newest column ends on `today`), so "best week" is a real column.
    static func window(countingDays: Set<Int>, dayMinutes: [Int: Double], sessionsByDay: [Int: Int],
                       weeks: Int, today: Int) -> Window {
        var active = 0, sessions = 0, best = 0
        var minutes = 0.0
        for col in 0..<weeks {
            var week = 0
            for row in 0..<7 {
                let day = today - ((weeks - 1 - col) * 7) - (6 - row)
                if countingDays.contains(day) { active += 1 }
                minutes += dayMinutes[day] ?? 0
                week += sessionsByDay[day] ?? 0
            }
            sessions += week
            best = max(best, week)
        }
        return Window(weeks: weeks, activeDays: active, activeMinutes: minutes,
                      sessions: sessions, bestWeekSessions: best)
    }
}
