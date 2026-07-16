import Foundation

/// The curated race catalog — the world's storied marathons, searchable from onboarding and plan
/// settings so pointing a season at "Chicago" takes two taps, not a typing exercise. We are not
/// affiliated with any race; dates are computed from each event's traditional calendar slot
/// (Boston = third Monday of April, NYC = first Sunday of November, …) so the catalog stays honest
/// and current every year without a feed. The UI says "estimate — confirm with your race" and the
/// picked date remains editable. Pure + deterministic; unit-tested date rules.
enum RaceCatalog {

    /// A race's traditional calendar slot: the `ordinal`-th `weekday` of `month`
    /// (ordinal -1 = last). Weekday uses Calendar's numbering (1 = Sunday … 7 = Saturday).
    struct DateRule: Sendable, Equatable {
        let month: Int
        let weekday: Int
        let ordinal: Int
        /// A fixed calendar day (Peachtree = July 4). When set, weekday/ordinal are ignored.
        var day: Int? = nil

        /// The next occurrence strictly after `date` (usually today) in the given calendar.
        func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
            let year = calendar.component(.year, from: date)
            for y in year...(year + 2) {
                guard let candidate = resolve(year: y, calendar: calendar) else { continue }
                if candidate > date { return candidate }
            }
            return nil
        }

        private func resolve(year: Int, calendar: Calendar) -> Date? {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            if let day {
                comps.day = day
                return calendar.date(from: comps)
            }
            comps.weekday = weekday
            if ordinal > 0 {
                comps.weekdayOrdinal = ordinal
                return calendar.date(from: comps)
            }
            // Last <weekday> of the month: try the 5th, fall back to the 4th.
            comps.weekdayOrdinal = 5
            if let fifth = calendar.date(from: comps),
               calendar.component(.month, from: fifth) == month { return fifth }
            comps.weekdayOrdinal = 4
            return calendar.date(from: comps)
        }
    }

    enum Region: String, CaseIterable, Sendable {
        case majors = "World Marathon Majors"
        case unitedStates = "United States"
        case international = "International"
    }

    struct Race: Identifiable, Sendable, Equatable {
        let id: String              // stable slug, e.g. "boston"
        let name: String
        let city: String
        let country: String
        let flag: String            // emoji — reads instantly, ships nothing
        let region: Region
        /// Distances offered on the event's weekend — flagship first (what the row leads with).
        let distances: [RaceDistance]
        let rule: DateRule

        var flagship: RaceDistance { distances[0] }

        func nextDate(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
            rule.nextOccurrence(after: date, calendar: calendar)
        }
    }

    // Weekday constants for readability (Calendar: 1 = Sunday).
    private static let sun = 1, mon = 2, sat = 7

    /// The catalog. Traditional slots per each race's public history — estimates, never promises.
    static let races: [Race] = [
        // World Marathon Majors — the seven stars, spotlighted first.
        Race(id: "boston", name: "Boston Marathon", city: "Boston", country: "USA", flag: "🇺🇸",
             region: .majors, distances: [.marathon], rule: .init(month: 4, weekday: mon, ordinal: 3)),
        Race(id: "london", name: "London Marathon", city: "London", country: "UK", flag: "🇬🇧",
             region: .majors, distances: [.marathon], rule: .init(month: 4, weekday: sun, ordinal: -1)),
        Race(id: "berlin", name: "Berlin Marathon", city: "Berlin", country: "Germany", flag: "🇩🇪",
             region: .majors, distances: [.marathon], rule: .init(month: 9, weekday: sun, ordinal: -1)),
        Race(id: "chicago", name: "Chicago Marathon", city: "Chicago", country: "USA", flag: "🇺🇸",
             region: .majors, distances: [.marathon], rule: .init(month: 10, weekday: sun, ordinal: 2)),
        Race(id: "nyc", name: "New York City Marathon", city: "New York", country: "USA", flag: "🇺🇸",
             region: .majors, distances: [.marathon], rule: .init(month: 11, weekday: sun, ordinal: 1)),
        Race(id: "tokyo", name: "Tokyo Marathon", city: "Tokyo", country: "Japan", flag: "🇯🇵",
             region: .majors, distances: [.marathon], rule: .init(month: 3, weekday: sun, ordinal: 1)),
        Race(id: "sydney", name: "Sydney Marathon", city: "Sydney", country: "Australia", flag: "🇦🇺",
             region: .majors, distances: [.marathon], rule: .init(month: 8, weekday: sun, ordinal: -1)),

        // United States — the big ones beyond the majors.
        Race(id: "la", name: "Los Angeles Marathon", city: "Los Angeles", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 3, weekday: sun, ordinal: 3)),
        Race(id: "houston", name: "Houston Marathon", city: "Houston", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 1, weekday: sun, ordinal: 3)),
        Race(id: "austin", name: "Austin Marathon", city: "Austin", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 2, weekday: sun, ordinal: 3)),
        Race(id: "marine-corps", name: "Marine Corps Marathon", city: "Washington, D.C.", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 10, weekday: sun, ordinal: -1)),
        Race(id: "philadelphia", name: "Philadelphia Marathon", city: "Philadelphia", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 11, weekday: sun, ordinal: 3)),
        Race(id: "twin-cities", name: "Twin Cities Marathon", city: "Minneapolis–St. Paul", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 10, weekday: sun, ordinal: 1)),
        Race(id: "grandmas", name: "Grandma's Marathon", city: "Duluth", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 6, weekday: sat, ordinal: 3)),
        Race(id: "cim", name: "California International Marathon", city: "Sacramento", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 12, weekday: sun, ordinal: 1)),
        Race(id: "big-sur", name: "Big Sur Marathon", city: "Big Sur", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 4, weekday: sun, ordinal: -1)),
        Race(id: "honolulu", name: "Honolulu Marathon", city: "Honolulu", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 12, weekday: sun, ordinal: 2)),
        Race(id: "sf", name: "San Francisco Marathon", city: "San Francisco", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 7, weekday: sun, ordinal: -1)),
        Race(id: "disney", name: "Walt Disney World Marathon", city: "Orlando", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half, .tenK, .fiveK], rule: .init(month: 1, weekday: sun, ordinal: 2)),
        Race(id: "st-george", name: "St. George Marathon", city: "St. George", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 10, weekday: sat, ordinal: 1)),
        Race(id: "richmond", name: "Richmond Marathon", city: "Richmond", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 11, weekday: sat, ordinal: 2)),
        Race(id: "monumental", name: "Indianapolis Monumental Marathon", city: "Indianapolis", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon], rule: .init(month: 11, weekday: sat, ordinal: 1)),

        // International icons.
        Race(id: "paris", name: "Paris Marathon", city: "Paris", country: "France", flag: "🇫🇷",
             region: .international, distances: [.marathon], rule: .init(month: 4, weekday: sun, ordinal: 2)),
        Race(id: "rotterdam", name: "Rotterdam Marathon", city: "Rotterdam", country: "Netherlands", flag: "🇳🇱",
             region: .international, distances: [.marathon], rule: .init(month: 4, weekday: sun, ordinal: 2)),
        Race(id: "amsterdam", name: "Amsterdam Marathon", city: "Amsterdam", country: "Netherlands", flag: "🇳🇱",
             region: .international, distances: [.marathon, .half], rule: .init(month: 10, weekday: sun, ordinal: 3)),
        Race(id: "valencia", name: "Valencia Marathon", city: "Valencia", country: "Spain", flag: "🇪🇸",
             region: .international, distances: [.marathon, .half], rule: .init(month: 12, weekday: sun, ordinal: 1)),
        Race(id: "barcelona", name: "Barcelona Marathon", city: "Barcelona", country: "Spain", flag: "🇪🇸",
             region: .international, distances: [.marathon], rule: .init(month: 3, weekday: sun, ordinal: 3)),
        Race(id: "rome", name: "Rome Marathon", city: "Rome", country: "Italy", flag: "🇮🇹",
             region: .international, distances: [.marathon], rule: .init(month: 3, weekday: sun, ordinal: 3)),
        Race(id: "hong-kong", name: "Hong Kong Marathon", city: "Hong Kong", country: "Hong Kong", flag: "🇭🇰",
             region: .international, distances: [.marathon], rule: .init(month: 2, weekday: sun, ordinal: 2)),
        Race(id: "great-wall", name: "Great Wall Marathon", city: "Tianjin", country: "China", flag: "🇨🇳",
             region: .international, distances: [.marathon, .half], rule: .init(month: 5, weekday: sat, ordinal: 3)),
        Race(id: "dublin", name: "Dublin Marathon", city: "Dublin", country: "Ireland", flag: "🇮🇪",
             region: .international, distances: [.marathon], rule: .init(month: 10, weekday: sun, ordinal: -1)),
        Race(id: "toronto", name: "Toronto Waterfront Marathon", city: "Toronto", country: "Canada", flag: "🇨🇦",
             region: .international, distances: [.marathon, .half], rule: .init(month: 10, weekday: sun, ordinal: 3)),
        Race(id: "vancouver", name: "Vancouver Marathon", city: "Vancouver", country: "Canada", flag: "🇨🇦",
             region: .international, distances: [.marathon], rule: .init(month: 5, weekday: sun, ordinal: 1)),
        Race(id: "mexico-city", name: "Mexico City Marathon", city: "Mexico City", country: "Mexico", flag: "🇲🇽",
             region: .international, distances: [.marathon], rule: .init(month: 8, weekday: sun, ordinal: -1)),
        Race(id: "athens", name: "Athens Authentic Marathon", city: "Athens", country: "Greece", flag: "🇬🇷",
             region: .international, distances: [.marathon], rule: .init(month: 11, weekday: sun, ordinal: 2)),
        Race(id: "singapore", name: "Singapore Marathon", city: "Singapore", country: "Singapore", flag: "🇸🇬",
             region: .international, distances: [.marathon, .half, .tenK], rule: .init(month: 12, weekday: sun, ordinal: 1)),
        Race(id: "cape-town", name: "Cape Town Marathon", city: "Cape Town", country: "South Africa", flag: "🇿🇦",
             region: .international, distances: [.marathon, .half], rule: .init(month: 10, weekday: sun, ordinal: 3)),
        // The storied halfs and shorter classics — most people race these.
        Race(id: "nyc-half", name: "NYC Half", city: "New York", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.half], rule: .init(month: 3, weekday: sun, ordinal: 3)),
        Race(id: "brooklyn-half", name: "Brooklyn Half", city: "Brooklyn", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.half], rule: .init(month: 5, weekday: sat, ordinal: 3)),
        Race(id: "bolder-boulder", name: "Bolder Boulder 10K", city: "Boulder", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.tenK], rule: .init(month: 5, weekday: mon, ordinal: -1)),
        Race(id: "great-north", name: "Great North Run", city: "Newcastle", country: "UK", flag: "🇬🇧",
             region: .international, distances: [.half], rule: .init(month: 9, weekday: sun, ordinal: 1)),
        Race(id: "atlanta", name: "Atlanta Marathon", city: "Atlanta", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 3, weekday: sun, ordinal: 1)),
        Race(id: "peachtree", name: "Peachtree Road Race", city: "Atlanta", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.tenK], rule: .init(month: 7, weekday: sun, ordinal: 1, day: 4)),
        Race(id: "miami", name: "Miami Marathon", city: "Miami", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 2, weekday: sun, ordinal: 1)),
        Race(id: "nashville", name: "Nashville Marathon", city: "Nashville", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 4, weekday: sat, ordinal: -1)),
        Race(id: "dallas", name: "Dallas Marathon", city: "Dallas", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 12, weekday: sun, ordinal: 2)),
        Race(id: "seattle", name: "Seattle Marathon", city: "Seattle", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 11, weekday: sun, ordinal: -1)),
        Race(id: "portland", name: "Portland Marathon", city: "Portland", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 10, weekday: sun, ordinal: 1)),
        Race(id: "detroit", name: "Detroit Marathon", city: "Detroit", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 10, weekday: sun, ordinal: 3)),
        Race(id: "columbus", name: "Columbus Marathon", city: "Columbus", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 10, weekday: sun, ordinal: 3)),
        Race(id: "baltimore", name: "Baltimore Marathon", city: "Baltimore", country: "USA", flag: "🇺🇸",
             region: .unitedStates, distances: [.marathon, .half], rule: .init(month: 10, weekday: sat, ordinal: 3)),
    ]

    /// Case- and diacritic-insensitive search over name, city, and country. Empty query → everything
    /// (grouped by region for display).
    static func search(_ query: String) -> [Race] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return races }
        return races.filter {
            $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.city.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.country.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// A natural-language resolution: the coach hears "set me up for the Chicago Marathon" or "I want
    /// to run the NYC half" and this returns the race, the distance the athlete meant (its flagship,
    /// or the sub-distance they named if the weekend offers it), and the computed next date — exactly
    /// what a `changeRace` needs. Deterministic and honest; nil when nothing clearly matches (so the
    /// coach can ask, never guess a race the athlete didn't name).
    struct Match: Sendable, Equatable {
        let race: Race
        let distance: RaceDistance
        let date: Date
    }

    /// Distance/filler words that describe ANY race — never distinctive enough to identify one.
    private static let genericTokens: Set<String> = [
        "marathon", "half", "full", "the", "a", "run", "running", "race", "road", "ultra",
        "5k", "10k", "50k", "city", "international", "authentic", "waterfront", "for", "to",
        "my", "want", "do", "next", "train", "training", "plan", "on", "in", "at", "of",
        // "new" alone must never identify a race ("start over with a NEW plan" is not the NEW York
        // Marathon); "york"/"nyc" stay distinctive, so the real ask still resolves.
        "new",
    ]

    static func match(freeText: String, after date: Date = Date(), calendar: Calendar = .current) -> Match? {
        let text = fold(freeText)
        guard !text.isEmpty else { return nil }
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let wanted = requestedDistance(in: text)

        var best: (race: Race, score: Int)?
        for race in races {
            // Distinctive tokens = the race's name + city words minus the generic descriptors.
            let tokens = (fold(race.name) + " " + fold(race.city))
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { $0.count >= 3 && !genericTokens.contains($0) }
            let hits = tokens.filter { words.contains($0) }.count
            guard hits > 0 else { continue }

            var score = hits * 3
            if let wanted, race.distances.contains(wanted) { score += 2 }   // "NYC half" → the race that offers a half
            if let wanted, race.flagship == wanted { score += 1 }
            if best == nil || score > best!.score { best = (race, score) }
        }
        guard let winner = best, let next = winner.race.nextDate(after: date, calendar: calendar) else { return nil }
        let distance = (wanted.flatMap { winner.race.distances.contains($0) ? $0 : nil }) ?? winner.race.flagship
        return Match(race: winner.race, distance: distance, date: next)
    }

    /// A distance the athlete named explicitly (else nil → use the race's flagship).
    private static func requestedDistance(in text: String) -> RaceDistance? {
        if text.contains("50k") || text.contains("ultra") { return .fiftyK }
        if text.contains("half") || text.contains("13.1") { return .half }
        if text.contains("10k") { return .tenK }
        if text.contains("5k") { return .fiveK }
        if text.contains("marathon") || text.contains("26.2") || text.contains("full") { return .marathon }
        return nil
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
