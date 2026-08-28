import Testing
import Foundation
@testable import Momentum

/// The numbers behind the consistency grid — walked over the grid's own cells, so what the depth
/// sheet says beneath the picture is the picture.
struct ConsistencyFactsTests {
    private let today = 20_000   // an arbitrary day ordinal

    @Test func activeDaysCountsOnlyInsideTheWindow() {
        let days: Set<Int> = [today, today - 1, today - 6, today - 7, today - 111, today - 112]
        #expect(ConsistencyFacts.activeDays(countingDays: days, weeks: 1, today: today) == 3)     // 7 days: today…-6
        #expect(ConsistencyFacts.activeDays(countingDays: days, weeks: 16, today: today) == 5)    // -112 is the 113th day back
        #expect(ConsistencyFacts.activeDays(countingDays: [], weeks: 16, today: today) == 0)
    }

    @Test func windowWalksTheGridsOwnColumns() {
        // Two sessions on the newest day, one six days back (same column), one 7 days back (the
        // previous column), and one far outside. Best week = the newest column's 3.
        let sessions: [Int: Int] = [today: 2, today - 6: 1, today - 7: 1, today - 200: 4]
        let minutes: [Int: Double] = [today: 90, today - 6: 20, today - 7: 45, today - 200: 300]
        let counting: Set<Int> = [today, today - 6, today - 7, today - 200]
        let w = ConsistencyFacts.window(countingDays: counting, dayMinutes: minutes,
                                        sessionsByDay: sessions, weeks: 2, today: today)
        #expect(w.weeks == 2 && w.windowDays == 14)
        #expect(w.activeDays == 3)
        #expect(w.sessions == 4)
        #expect(w.bestWeekSessions == 3)
        #expect(abs(w.activeMinutes - 155) < 0.000_1)
        #expect(abs(w.sessionsPerWeek - 2.0) < 0.000_1)
    }

    @Test func emptyWindowIsAllZeros() {
        let w = ConsistencyFacts.window(countingDays: [], dayMinutes: [:], sessionsByDay: [:],
                                        weeks: 26, today: today)
        #expect(w == ConsistencyFacts.Window(weeks: 26, activeDays: 0, activeMinutes: 0,
                                             sessions: 0, bestWeekSessions: 0))
        #expect(w.sessionsPerWeek == 0)
    }

    @Test func cardHeadlineAndSheetAgree() {
        // The card's headline (`activeDays`) and the sheet's window read the same cells.
        var days = Set<Int>()
        for d in stride(from: 0, to: 16 * 7, by: 3) { days.insert(today - d) }
        let card = ConsistencyFacts.activeDays(countingDays: days, weeks: 16, today: today)
        let sheet = ConsistencyFacts.window(countingDays: days, dayMinutes: [:], sessionsByDay: [:],
                                            weeks: 16, today: today).activeDays
        #expect(card == sheet)
    }
}
