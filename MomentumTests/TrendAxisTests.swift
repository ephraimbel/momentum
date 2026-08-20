import Testing
import Foundation
@testable import Momentum

/// Pins the axis-alignment law (2026-08-19): labels are always a subset of the series' own
/// dates (a label can only sit under a mark that exists), the newest point always labels, and
/// month-only regimes never repeat a month. These invariants are what "the dates line up with
/// the bars" means — if any of them regress, labels drift off the marks again.
struct TrendAxisTests {

    private func days(_ n: Int, from start: Date = Date(timeIntervalSince1970: 1_750_000_000)) -> [Date] {
        (0..<n).map { start.addingTimeInterval(Double($0) * 86_400) }
    }

    /// Rolling weeks like the engines produce: anchored to an arbitrary weekday + wall-clock time.
    private func rollingWeeks(_ n: Int) -> [Date] {
        let anchor = Date(timeIntervalSince1970: 1_752_345_678)   // deliberately mid-week, mid-day
        return (0..<n).map { anchor.addingTimeInterval(Double($0) * 7 * 86_400) }
    }

    @Test func labelsAreAlwaysASubsetOfTheData() {
        for dates in [days(7), days(30), days(120), rollingWeeks(5), rollingWeeks(13),
                      rollingWeeks(26), rollingWeeks(52)] {
            let daily = dates.count > 1 && dates[1].timeIntervalSince(dates[0]) < 3 * 86_400
            let labels = TrendAxis.labelDates(for: dates, granularity: daily ? .daily : .weekly)
            let set = Set(dates)
            #expect(!labels.isEmpty)
            #expect(labels.allSatisfy { set.contains($0) },
                    "every label must sit on a real data point (count \(dates.count))")
        }
    }

    @Test func newestPointAlwaysCarriesALabel() {
        for dates in [days(7), days(14), days(35), rollingWeeks(13), rollingWeeks(26), rollingWeeks(52)] {
            let daily = dates.count > 1 && dates[1].timeIntervalSince(dates[0]) < 3 * 86_400
            let labels = TrendAxis.labelDates(for: dates, granularity: daily ? .daily : .weekly)
            #expect(labels.last == dates.last,
                    "the newest bar is the one the athlete looks for — it must be labeled")
        }
    }

    @Test func weekOfBarsLabelsEveryBar() {
        let labels = TrendAxis.labelDates(for: days(7), granularity: .daily)
        #expect(labels.count == 7)   // weekday letter under every bar, the Oura week view
        #expect(TrendAxis.labelForm(count: 7, granularity: .daily) == .weekdayNarrow)
    }

    @Test func monthOnlyRegimeNeverRepeatsAMonth() {
        for dates in [rollingWeeks(26), rollingWeeks(52), days(180), days(365)] {
            let daily = dates.count > 1 && dates[1].timeIntervalSince(dates[0]) < 3 * 86_400
            let g: TrendAxis.Granularity = daily ? .daily : .weekly
            guard TrendAxis.labelForm(count: dates.count, granularity: g) == .monthOnly else { continue }
            let labels = TrendAxis.labelDates(for: dates, granularity: g)
            let cal = Calendar.current
            let months = labels.map { cal.dateComponents([.year, .month], from: $0) }
            #expect(Set(months.map { "\($0.year ?? 0)-\($0.month ?? 0)" }).count == months.count,
                    "a month must never label twice (the 'Jun · Jun' rule)")
        }
    }

    @Test func labelCountStaysReadable() {
        for dates in [days(30), days(120), rollingWeeks(13), rollingWeeks(26), rollingWeeks(52)] {
            let daily = dates.count > 1 && dates[1].timeIntervalSince(dates[0]) < 3 * 86_400
            let labels = TrendAxis.labelDates(for: dates, granularity: daily ? .daily : .weekly)
            #expect(labels.count <= 7, "axis crowding: \(labels.count) labels for \(dates.count) points")
            #expect(labels.count >= 2)
        }
    }

    @Test func domainPadsHalfTheSpacingEachSide() {
        let weeks = rollingWeeks(13)
        let domain = TrendAxis.domain(for: weeks, granularity: .weekly)
        let half = 3.5 * 86_400
        #expect(abs(domain.lowerBound.timeIntervalSince(weeks.first!) + half) < 60)
        #expect(abs(domain.upperBound.timeIntervalSince(weeks.last!) - half) < 60)
        // Single point / empty never produce an inverted or zero-width domain.
        let single = TrendAxis.domain(for: [weeks[0]], granularity: .daily)
        #expect(single.lowerBound < single.upperBound)
        let empty = TrendAxis.domain(for: [], granularity: .weekly)
        #expect(empty.lowerBound < empty.upperBound)
    }

    @Test func domainSurvivesAGapInTheSeries() {
        // A missing bucket mustn't stretch the edge padding (median spacing, not mean).
        var dates = days(10)
        dates.removeSubrange(4...6)
        let domain = TrendAxis.domain(for: dates, granularity: .daily)
        #expect(abs(domain.lowerBound.timeIntervalSince(dates.first!) + 43_200) < 60)
    }
}
