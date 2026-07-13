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

    @Test func fixedDateClassicsLandOnTheirDay() {
        // Peachtree Road Race is July 4th, every year — a fixed date, not a weekend rule.
        #expect(race("peachtree").nextDate(after: date(2026, 7, 15), calendar: cal) == date(2027, 7, 4))
        #expect(race("peachtree").nextDate(after: date(2027, 1, 1), calendar: cal) == date(2027, 7, 4))
    }

    @Test func unitedStatesCoverageSpansTheMap() {
        // Every region of the country sees itself: Northeast, Southeast, Midwest, South, West,
        // Pacific Northwest, plus Hawaii and the mountain states.
        let usCities = Set(RaceCatalog.races.filter { $0.country == "USA" }.map(\.city))
        for city in ["Boston", "New York", "Philadelphia", "Atlanta", "Miami", "Nashville",
                     "Chicago", "Detroit", "Columbus", "Minneapolis–St. Paul", "Indianapolis",
                     "Houston", "Austin", "Dallas", "Los Angeles", "San Francisco", "Sacramento",
                     "Seattle", "Portland", "Boulder", "St. George", "Honolulu", "Washington, D.C.",
                     "Baltimore"] {
            #expect(usCities.contains(city), "missing US coverage: \(city)")
        }
        #expect(RaceCatalog.races.filter { $0.country == "USA" }.count >= 25)
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

    @Test func naturalLanguageMatchResolvesNamedRaces() {
        // The coach hears a phrase and gets the race + distance + our computed date — deterministic.
        let ref = date(2026, 1, 1)
        let chicago = RaceCatalog.match(freeText: "set me up for the Chicago Marathon", after: ref)
        #expect(chicago?.race.id == "chicago")
        #expect(chicago?.distance == .marathon)
        #expect(chicago?.date == date(2026, 10, 11))                 // Chicago's traditional weekend

        // A named sub-distance wins the right event: "NYC half" → the half, not the NYC marathon.
        let nycHalf = RaceCatalog.match(freeText: "I want to run the NYC half", after: ref)
        #expect(nycHalf?.distance == .half)
        #expect(nycHalf?.race.distances.contains(.half) == true)

        // City-only, flagship distance.
        #expect(RaceCatalog.match(freeText: "train for boston", after: ref)?.race.id == "boston")
        #expect(RaceCatalog.match(freeText: "hong kong marathon", after: ref)?.race.id == "hong-kong")
    }

    @Test func naturalLanguageMatchRefusesWhenUnclear() {
        // No named race → nil, so the coach asks instead of inventing one.
        #expect(RaceCatalog.match(freeText: "I want to run a marathon someday") == nil)
        #expect(RaceCatalog.match(freeText: "make my plan harder") == nil)
        #expect(RaceCatalog.match(freeText: "") == nil)
    }

    @Test func catalogHygiene() {
        // Stable unique ids, all seven majors present, every event offers at least one distance.
        #expect(Set(RaceCatalog.races.map(\.id)).count == RaceCatalog.races.count)
        #expect(RaceCatalog.races.filter { $0.region == .majors }.count == 7)
        #expect(RaceCatalog.races.allSatisfy { !$0.distances.isEmpty })
        #expect(RaceCatalog.races.filter { $0.region == .majors }.allSatisfy { $0.flagship == .marathon })
        #expect(RaceCatalog.races.allSatisfy { !$0.name.isEmpty && !$0.city.isEmpty && !$0.flag.isEmpty })
    }

    @Test func raceWeekendsOfferSubDistances() {
        // The big weekends carry their halfs and shorter classics — most people race those.
        #expect(race("houston").distances.contains(.half))
        #expect(race("disney").distances == [.marathon, .half, .tenK, .fiveK])
        #expect(race("disney").flagship == .marathon)                 // flagship stays first
        // Standalone half/10K classics exist in their regions.
        #expect(race("nyc-half").distances == [.half])
        #expect(race("great-north").distances == [.half])
        #expect(race("bolder-boulder").distances == [.tenK])
        // Every offered distance is unique per event (no duplicate chips).
        for r in RaceCatalog.races {
            #expect(Set(r.distances).count == r.distances.count, "\(r.id): duplicate distances")
        }
    }
}
