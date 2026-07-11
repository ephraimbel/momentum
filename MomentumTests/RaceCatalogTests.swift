import Testing
import Foundation
@testable import Momentum

/// The curated race catalog — date rules verified against the real calendar (Boston is the third
/// Monday of April, NYC the first Sunday of November, …), search behavior, and catalog hygiene.
struct RaceCatalogTests {

    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func race(_ id: String) -> RaceCatalog.Race { RaceCatalog.races.first { $0.id == id }! }

    @Test func majorsLandOnTheirTraditionalWeekends() {
        // Boston: third Monday of April → Apr 19, 2027.
        #expect(race("boston").nextDate(after: date(2026, 12, 1), calendar: cal) == date(2027, 4, 19))
        // NYC: first Sunday of November → Nov 1, 2026; the day after, it rolls to Nov 7, 2027.
        #expect(race("nyc").nextDate(after: date(2026, 7, 15), calendar: cal) == date(2026, 11, 1))
        #expect(race("nyc").nextDate(after: date(2026, 11, 2), calendar: cal) == date(2027, 11, 7))
        // Berlin: LAST Sunday of September → Sep 27, 2026 (a five-Sunday month is handled).
        #expect(race("berlin").nextDate(after: date(2026, 7, 15), calendar: cal) == date(2026, 9, 27))
        // Chicago: second Sunday of October → Oct 11, 2026.
        #expect(race("chicago").nextDate(after: date(2026, 7, 15), calendar: cal) == date(2026, 10, 11))
    }

    @Test func everyRaceAlwaysHasAnUpcomingDate() {
        // From any reference point, every race resolves to a real future date within ~13 months —
        // the picker never shows a dead row.
        for reference in [date(2026, 1, 1), date(2026, 7, 15), date(2026, 12, 31)] {
            for r in RaceCatalog.races {
                let next = r.nextDate(after: reference, calendar: cal)
                #expect(next != nil, "\(r.id): no upcoming date")
                if let next {
                    #expect(next > reference, "\(r.id): date not in the future")
                    let days = cal.dateComponents([.day], from: reference, to: next).day ?? 0
                    #expect(days <= 400, "\(r.id): next occurrence unreasonably far (\(days)d)")
                }
            }
        }
    }

    @Test func searchFindsByNameCityAndCountry() {
        #expect(RaceCatalog.search("chi").contains { $0.id == "chicago" })
        #expect(RaceCatalog.search("hong").contains { $0.id == "hong-kong" })
        #expect(RaceCatalog.search("sacramento").contains { $0.id == "cim" })     // city → race
        #expect(RaceCatalog.search("japan").contains { $0.id == "tokyo" })        // country → race
        #expect(RaceCatalog.search("BOSTON").contains { $0.id == "boston" })      // case-insensitive
        #expect(RaceCatalog.search("zzzz").isEmpty)
        #expect(RaceCatalog.search("").count == RaceCatalog.races.count)
    }

    @Test func catalogHygiene() {
        // Stable unique ids, all seven majors present, every race a real marathon distance.
        #expect(Set(RaceCatalog.races.map(\.id)).count == RaceCatalog.races.count)
        #expect(RaceCatalog.races.filter { $0.region == .majors }.count == 7)
        #expect(RaceCatalog.races.allSatisfy { $0.distance == .marathon })
        #expect(RaceCatalog.races.allSatisfy { !$0.name.isEmpty && !$0.city.isEmpty && !$0.flag.isEmpty })
    }
}
