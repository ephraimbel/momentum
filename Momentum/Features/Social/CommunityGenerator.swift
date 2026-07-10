import Foundation

/// Generates a large, deterministic **Momentum community** (docs/SOCIAL-LAYER.md). Honest presence:
/// every generated athlete is clearly labeled community content in the UI (never a real stranger near
/// you). Deterministic (index-seeded) so the feed + globe are stable across launches. Athletes sit at
/// real cities — **US-majority** — with small jitter so globe dots land on cities (not the ocean), and
/// each GPS post carries a real short route + a varied map style so the feed shows real maps.
enum CommunityGenerator {
    static let count = 950

    static func generate(now: Date) -> [CommunityAthlete] {
        (0..<count).map { athlete(index: $0, now: now) }
    }

    private static func athlete(index i: Int, now: Date) -> CommunityAthlete {
        var rng = SeededRNG(i &* 2654435761)
        let first = rng.pick(firstNames)
        let last = rng.pick(lastNames)
        let name = "\(first) \(last)"
        let handle = "\(first.lowercased())\(last.prefix(1).lowercased())\(i + 10)"
        // ~78% US so the map is majority-US; real cities + tight jitter keep dots on land.
        let city = rng.int(0...99) < 78 ? rng.pick(usCities) : rng.pick(worldCities)
        let discipline = rng.pick(disciplines)

        let workouts = rng.int(40...900)
        let streak = rng.int(0...44)
        let distance = Double(rng.int(120...9800)) * 1000

        // Dot jitter is tight so it stays on the city (not offshore); the route anchors on the city
        // center (downtown = land) rather than the jittered dot, so traces don't start in the water.
        let lat = city.lat + rng.double(-0.02, 0.02)
        let lon = city.lon + rng.double(-0.02, 0.02)
        // Post content is salted by the calendar day: identities never change (a followed handle
        // must not vanish overnight), but everyone's latest post rotates daily — a returning user
        // opens a NEW page every day, not the same feed frozen forever. Deterministic within a day.
        let day = Int(now.timeIntervalSince1970 / 86_400)
        var postRng = SeededRNG(i &* 48_271 &+ day &* 92_821)
        // Recency-weighted post ages: a big slice of the community posted within the last few
        // hours, so the top of the feed reads "3 min ago, 40 min ago, 2 hr ago" like a page people
        // are actively using — not a uniform smear across four days. Exponent 1.7 keeps the newest
        // posts SPREAD across the first hour (a steeper curve piles dozens onto one identical
        // "9 minutes ago", which is its own fake tell).
        let u = postRng.double(0, 1)
        let postDate = now.addingTimeInterval(-(0.05 + 96 * pow(u, 1.7)) * 3600)
        let post = makePost(index: i, name: name, handle: handle, city: city.name,
                            discipline: discipline, lat: city.lat, lon: city.lon, date: postDate, rng: &postRng)

        return CommunityAthlete(
            handle: handle, name: name, location: city.name, bio: rng.pick(bios),
            totalWorkouts: workouts, dayStreak: streak, totalDistanceM: distance,
            lat: lat, lon: lon, posts: [post])
    }

    /// A visited athlete's grid history — the older posts behind their most recent share, so their
    /// profile reads like a real training log (~10 weeks deep) rather than a single tile. Generated
    /// on demand per athlete (deterministic — seeded from the handle), NOT folded into the feed:
    /// the feed stays one-recent-post-per-athlete, exactly as before.
    static func historyPosts(handle: String, name: String, city: String,
                             count: Int, now: Date) -> [FeedItem] {
        var rng = SeededRNG(handle.utf8.reduce(11) { ($0 &* 131 &+ Int($1)) & 0x7FFF_FFFF })
        // A stable per-athlete discipline mix: mostly running, seasoned with rides + lifting.
        var date = now.addingTimeInterval(-Double(rng.int(30...90)) * 3600)
        return (0..<count).map { j in
            let roll = rng.int(0...99)
            let discipline: WorkoutType = roll < 62 ? .run : (roll < 76 ? .ride : (roll < 92 ? .strength : .hiit))
            date = date.addingTimeInterval(-Double(rng.int(30...110)) * 3600)   // every 1–4½ days back
            // Unique, deterministic id-space far away from the feed posts' indices.
            let index = 500_000 + (handle.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }) * 100 + j
            return makePost(index: index, name: name, handle: handle, city: city,
                            discipline: discipline, lat: 0, lon: 0, date: date, rng: &rng)
        }
    }

    /// A brand-new post for `athlete`, dated moments ago — the pull-to-refresh pulse uses these so
    /// refreshing the page always surfaces something that just happened. Deterministic per
    /// (pulse, slot); ids live in their own space (8M+) far from feed (0+) and history (500k+) posts.
    static func freshPost(for athlete: CommunityAthlete, pulse: Int, slot: Int, now: Date) -> FeedItem {
        var rng = SeededRNG(pulse &* 48_611 &+ slot &* 7_129 &+ 977)
        let roll = rng.int(0...99)
        let discipline: WorkoutType = roll < 62 ? .run : (roll < 78 ? .ride : (roll < 90 ? .strength : .walk))
        let date = now.addingTimeInterval(-rng.double(0.5, 6) * 60)
        return makePost(index: 8_000_000 + pulse * 50 + slot, name: athlete.name,
                        handle: athlete.handle, city: athlete.location ?? "Austin, TX",
                        discipline: discipline, lat: athlete.lat, lon: athlete.lon,
                        date: date, rng: &rng)
    }

    private static func makePost(index i: Int, name: String, handle: String, city: String,
                                 discipline: WorkoutType, lat: Double, lon: Double, date: Date,
                                 rng: inout SeededRNG) -> FeedItem {
        let id = UUID(uuidString: "00000000-0000-0000-0001-\(String(format: "%012d", i))")!
        let reactions = rng.int(0...140)
        let caption = rng.int(0...2) == 0 ? nil : rng.pick(captions(for: discipline))
        let style = feedStyles[rng.int(0...(feedStyles.count - 1))]
        // A REAL street-following loop from the bundled Directions fetch — never a synthetic
        // shape over rooftops. If a city has no bundled loop, the post ships without a map
        // (an honest gap beats an obviously fake trace).
        let loop = discipline.isGPS ? CommunityRoutes.loop(city: city, discipline: discipline, rng: &rng) : nil
        let (title, stat, pr) = content(for: discipline, routeKm: loop?.km, rng: &rng)
        let muscles = discipline.isStrengthStyle ? StrengthFeedMuscles.activation(forTitle: title, type: discipline) : nil
        let ai = rng.int(0...2) == 0 ? rng.pick(aiReads) : nil
        return FeedItem(id: id, authorName: name, authorHandle: handle, location: city,
                        isCommunity: true, type: discipline, date: date, title: title, caption: caption,
                        statLine: stat, prBadge: pr, muscles: muscles, routeLatLon: loop?.pts, mapStyle: style,
                        baseReactions: reactions, aiRead: ai)
    }

    /// "MM:SS" / "H:MM:SS" from seconds — with real seconds, because real workouts don't all
    /// end on a round minute.
    static func durationString(seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "X.X mi · T" where T is derived from the route's TRUE length at a plausible pace for the
    /// discipline — the map and the numbers always agree.
    private static func gpsStat(km: Double, paceSecPerKm: Double, rng: inout SeededRNG) -> String {
        let seconds = Int(km * paceSecPerKm + rng.double(0, 59))
        return String(format: "%.1f mi · %@", km * 0.621371, durationString(seconds: seconds))
    }

    /// PR badges must match the sport — a "Longest ride" on a run post is an instant fake tell.
    private static func prLabel(for discipline: WorkoutType, rng: inout SeededRNG) -> String? {
        guard rng.int(0...6) == 0 else { return nil }
        switch discipline {
        case .run, .trailRun: return rng.pick(["5K PR", "Fastest mile", "Longest run"])
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide: return "Longest ride"
        case .hike: return "Longest hike"
        case .strength, .crossfit: return rng.pick(["e1RM PR", "Most volume"])
        default: return nil
        }
    }

    private static func content(for discipline: WorkoutType, routeKm: Double?,
                                rng: inout SeededRNG) -> (String, String, String?) {
        let pr = prLabel(for: discipline, rng: &rng)
        switch discipline {
        case .run:
            // 4:40–7:10 /km ≈ 7:30–11:30 /mi — everyday-runner territory.
            return (rng.pick(runTitles),
                    gpsStat(km: routeKm ?? rng.double(3, 12), paceSecPerKm: rng.double(280, 430), rng: &rng), pr)
        case .trailRun:
            // Slower paces (5:35–7:40 /km). Trail titles ONLY when there's no route map — the
            // bundled loops trace city streets, and "Singletrack miles" over downtown blocks is a
            // fake tell. With a street map these read as easy road runs, which the pace matches.
            return (rng.pick(routeKm == nil ? trailTitles : easyRunTitles),
                    gpsStat(km: routeKm ?? rng.double(5, 15), paceSecPerKm: rng.double(335, 460), rng: &rng), pr)
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide:
            // 20–31 km/h ≈ 12–19 mph.
            return (rng.pick(rideTitles),
                    gpsStat(km: routeKm ?? rng.double(15, 45), paceSecPerKm: rng.double(116, 180), rng: &rng), pr)
        case .walk, .hike:
            // 10:00–14:30 /km ≈ 16–23 min/mi. Hike/trail titles only WITHOUT a route map — the
            // bundled loops trace city streets, and "Trail walk" over downtown blocks reads fake.
            return (rng.pick(routeKm == nil ? walkTitles : urbanWalkTitles),
                    gpsStat(km: routeKm ?? rng.double(2, 8), paceSecPerKm: rng.double(600, 870), rng: &rng), pr)
        case .strength, .crossfit, .hiit:
            let vol = rng.int(4...22) * 1000
            let seconds = rng.int(35 * 60...80 * 60)
            return (rng.pick(liftTitles), "\(vol.formatted()) lb · \(rng.int(8...26)) sets · \(durationString(seconds: seconds))", pr)
        default:
            // Timed sports get their OWN titles — "Pool intervals" on a yoga post is a fake tell.
            let titles: [String] = switch discipline {
            case .swimming: swimTitles
            case .rowing: rowTitles
            case .yoga: yogaTitles
            default: otherTitles
            }
            return (rng.pick(titles), durationString(seconds: rng.int(20 * 60...70 * 60)), pr)
        }
    }

    // MARK: Pools
    private static let firstNames = ["Maya","Theo","Lin","Priya","Marcus","Sofia","Devon","Amara","Jamal","Nina","Owen","Yuki","Diego","Hana","Liam","Zara","Noah","Aisha","Caleb","Mei","Andre","Ravi","Elena","Kofi","Ines","Tomas","Leila","Sven","Rosa","Kai","Bianca","Omar","Freya","Hugo","Tara","Mateo","Ada","Joon","Carmen","Felix","Nadia","Pablo","Greta","Sami","Lucia","Dario","Mira","Esme","Cole","Jade"]
    private static let lastNames = ["Rivera","Bennett","Chen","Nair","Hill","Alvarez","Kim","Okafor","Reed","Petrov","Lowe","Sato","Mendez","Park","Walsh","Haddad","Cohen","Diallo","Brooks","Tan","Costa","Iyer","Novak","Mensah","Roca","Berg","Faraj","Lindqvist","Santos","Wu","Foster","Nguyen","Carter","Patel","Ramos","Bauer","Flores","Quinn","Ward","Cole"]

    /// US cities (real coords) — the bulk of the community.
    private static let usCities: [(name: String, lat: Double, lon: Double)] = [
        ("Austin, TX",30.27,-97.74),("New York, NY",40.78,-73.97),("Los Angeles, CA",34.05,-118.24),
        ("Chicago, IL",41.88,-87.63),("Denver, CO",39.74,-104.99),("Seattle, WA",47.62,-122.31),
        ("Boston, MA",42.34,-71.10),("San Francisco, CA",37.77,-122.42),("Portland, OR",45.52,-122.64),
        ("Miami, FL",25.77,-80.25),("Boulder, CO",40.01,-105.27),("San Diego, CA",32.75,-117.13),
        ("Dallas, TX",32.78,-96.80),("Houston, TX",29.76,-95.37),("Atlanta, GA",33.75,-84.39),
        ("Phoenix, AZ",33.45,-112.07),("Philadelphia, PA",39.95,-75.17),("Minneapolis, MN",44.98,-93.27),
        ("Nashville, TN",36.16,-86.78),("Charlotte, NC",35.23,-80.84),("Salt Lake City, UT",40.76,-111.89),
        ("Washington, DC",38.91,-77.04),("San Antonio, TX",29.42,-98.49),("Sacramento, CA",38.58,-121.49),
        ("Columbus, OH",39.96,-83.00),("Indianapolis, IN",39.77,-86.16),("Kansas City, MO",39.10,-94.58),
        ("Raleigh, NC",35.78,-78.64),("Pittsburgh, PA",40.44,-79.996),("Milwaukee, WI",43.04,-87.91),
        ("Tampa, FL",27.97,-82.44),("Orlando, FL",28.54,-81.38),("Las Vegas, NV",36.17,-115.14),
        ("Madison, WI",43.07,-89.40),("Richmond, VA",37.54,-77.44),("Asheville, NC",35.60,-82.55),
        ("Boise, ID",43.62,-116.21),("Bend, OR",44.06,-121.31),("Fort Collins, CO",40.59,-105.08),
        ("Ann Arbor, MI",42.28,-83.74),("Brooklyn, NY",40.68,-73.94),("Oakland, CA",37.80,-122.27),
        ("St. Louis, MO",38.63,-90.20),("Cincinnati, OH",39.10,-84.51),("New Orleans, LA",29.96,-90.09)]

    /// Non-US cities — the rest of the community.
    private static let worldCities: [(name: String, lat: Double, lon: Double)] = [
        ("London",51.51,-0.13),("Toronto",43.66,-79.40),("Sydney",-33.89,151.20),("Berlin",52.52,13.40),
        ("Paris",48.86,2.35),("Vancouver",49.25,-123.10),("Melbourne",-37.81,144.96),("Dublin",53.35,-6.26),
        ("Amsterdam",52.37,4.90),("Madrid",40.42,-3.70),("Tokyo",35.68,139.69),("Auckland",-36.89,174.76),
        ("Stockholm",59.35,18.04),("Mexico City",19.43,-99.13),("Barcelona",41.41,2.16),("Munich",48.14,11.58),
        ("Calgary",51.05,-114.07),("Cape Town",-33.96,18.47),("Singapore",1.35,103.82),("Oslo",59.93,10.76)]

    // No em-dashes anywhere in generated copy — dashes read as machine-written (user call
    // 2026-07-10). Everything below is written the way people actually type on a feed.
    private static let bios = [
        "Hybrid athlete. Lift heavy, move fast.","Marathoner in training. Coffee, then miles.",
        "Just here to beat yesterday.","Consistency over intensity.","Weekend warrior, weekday grinder.",
        "Chasing PRs and good sunrises.","Run streak in progress.","Strong is the goal.",
        "5am club.","Slow miles, big base.","Training for my first ultra.","Dad of two, runner of many miles.",
        "Physio by day, trail runner by weekend.","Half marathon szn.","Back after an injury. Patient this time."]
    /// Captions must fit the sport ("negative split" on a lift post is a fake tell).
    private static func captions(for discipline: WorkoutType) -> [String] {
        if discipline.isStrengthStyle {
            return neutralCaptions + [
                "Heavy but moving well.", "All the reps in the bank.", "Bar felt light today.",
                "Last set was a fight.", "Volume day done.", "New gym, same work.",
                "Grip gave out before the legs did lol", "Told myself 5 sets. Did 8."]
        }
        if discipline == .walk || discipline == .hike {
            // Walks don't negative-split or chase PRs — their captions are about the reset.
            return neutralCaptions + [
                "Nice reset.", "Podcast miles.", "Fresh air fixed it.", "Perfect weather for it.",
                "Legs needed this.", "Slow on purpose."]
        }
        if discipline.isGPS {
            return neutralCaptions + [
                "Negative split the whole way.", "Legs heavy, heart full.", "Easy effort, big smile.",
                "Beat my old time.", "Perfect weather for it.", "Almost bailed at mile 2. Glad I didn't.",
                "First run in new shoes and yeah, believers now", "Humid one today 🥵",
                "Sunrise did all the work.", "Didn't want to. Did it anyway."]
        }
        return neutralCaptions
    }
    private static let neutralCaptions = [
        "Felt strong today.", "Tough one but worth it.", "Dialed in.", "Showed up. That's the win.",
        "Not my best, still counts.", "Day 1 of the new block.", "Body said no, did it anyway."]
    private static let runTitles = ["Morning run","Tempo run","Long run","Easy miles","Sunrise tempo","Track session","Recovery jog","Lunch run","Night run","Progression run","Shakeout"]
    private static let rideTitles = ["Morning ride","Hill repeats","Long ride","Gravel loop","Coffee ride","Interval ride","Sunset spin"]
    private static let trailTitles = ["Trail run","Ridge loop","Singletrack miles","Dirt hour","Trail tempo"]
    private static let easyRunTitles = ["Easy miles","Recovery jog","Easy run","Slow miles","Base miles"]
    private static let walkTitles = ["Recovery walk","Evening walk","Hike","Trail walk","Steps day"]
    private static let urbanWalkTitles = ["Recovery walk","Evening walk","Morning walk","Neighborhood loop","Steps day"]
    private static let liftTitles = ["Push day","Pull day","Lower power","Upper hypertrophy","Full body","Leg day","Conditioning"]
    private static let swimTitles = ["Pool intervals","Morning laps","Easy swim","Swim session"]
    private static let rowTitles = ["Steady state","Erg intervals","Morning meters","Row session"]
    private static let yogaTitles = ["Flow","Mobility","Evening flow","Stretch and reset"]
    private static let otherTitles = ["Session","Steady state","Conditioning","Open mat"]
    /// Sample "Momentum read" lines shown in a post's reading view (clearly community/sample
    /// content, never presented as analysis of a real stranger).
    private static let aiReads = [
        "A controlled effort. Heart rate stayed in the aerobic band the whole way, so this builds the engine without adding fatigue.",
        "Strong finish: the last third was the fastest, which is exactly how you want a steady session to end.",
        "Volume landed right in the productive range. Pair it with an easy day tomorrow and the adaptation sticks.",
        "Consistent splits and a relaxed cadence. This is the kind of repeatable session that compounds over months.",
        "Effort matched the plan. Nothing flashy, just another deposit in the consistency account.",
        "Good intensity discipline: held back early, had something left to give late."]
    /// Variety of basemaps across the feed (Strava-style "people use different maps"). No satellite —
    /// aerial imagery is off-brand and removed from the app's map choices.
    static let feedStyles: [MapStyleOption] = [.standard, .realistic, .streets, .outdoors, .dark]
    private static let disciplines: [WorkoutType] = [.run,.run,.ride,.walk,.trailRun,.strength,.strength,.hiit,.swimming,.rowing,.yoga]
}

/// Session-scoped "someone just posted" pulses: each pull-to-refresh mints a few brand-new
/// community posts dated moments ago, so refreshing always lands something fresh up top — the
/// page reads as live, never static. Deterministic per pulse; state resets with the process.
@MainActor
enum CommunityPulse {
    private static var pulse = 0
    private static var usedHandles: Set<String> = []

    /// Returns `existing` with 2–4 fresh posts prepended (newest first). Featured athletes
    /// (indices 0..<8) are skipped so the hand-curated voices don't double-post, and each
    /// generated athlete pulses at most once per session.
    static func refreshed(_ existing: [FeedItem], now: Date = Date()) -> [FeedItem] {
        let athletes = CommunityDirectory.all()
        guard athletes.count > 12 else { return existing }
        pulse += 1
        var rng = SeededRNG(pulse &* 104_729)
        var fresh: [FeedItem] = []
        for slot in 0..<rng.int(2...4) {
            var pick = athletes[rng.int(8...(athletes.count - 1))]
            var tries = 0
            while usedHandles.contains(pick.handle), tries < 8 {
                pick = athletes[rng.int(8...(athletes.count - 1))]; tries += 1
            }
            usedHandles.insert(pick.handle)
            fresh.append(CommunityGenerator.freshPost(for: pick, pulse: pulse, slot: slot, now: now))
        }
        return (fresh + existing).sorted { $0.date > $1.date }
    }
}

/// Tiny deterministic PRNG (LCG) — stable seeded values for the generated community.
struct SeededRNG {
    private var state: UInt64
    init(_ seed: Int) { state = UInt64(bitPattern: Int64(seed)) &* 2862933555777941757 &+ 3037000493 }
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
    mutating func double(_ lo: Double, _ hi: Double) -> Double { lo + Double(next() % 10_000) / 10_000 * (hi - lo) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }
}
