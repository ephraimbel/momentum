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
        let postDate = now.addingTimeInterval(-rng.double(0.3, 96) * 3600)
        let post = makePost(index: i, name: name, handle: handle, city: city.name,
                            discipline: discipline, lat: city.lat, lon: city.lon, date: postDate, rng: &rng)

        return CommunityAthlete(
            handle: handle, name: name, location: city.name, bio: rng.pick(bios),
            totalWorkouts: workouts, dayStreak: streak, totalDistanceM: distance,
            lat: lat, lon: lon, posts: [post])
    }

    private static func makePost(index i: Int, name: String, handle: String, city: String,
                                 discipline: WorkoutType, lat: Double, lon: Double, date: Date,
                                 rng: inout SeededRNG) -> FeedItem {
        let id = UUID(uuidString: "00000000-0000-0000-0001-\(String(format: "%012d", i))")!
        let reactions = rng.int(0...140)
        let caption = rng.int(0...2) == 0 ? nil : rng.pick(captions)
        let style = feedStyles[rng.int(0...(feedStyles.count - 1))]
        let route: [[Double]]? = discipline.isGPS ? loopRoute(lat: lat, lon: lon, rng: &rng) : nil
        let (title, stat, pr) = content(for: discipline, rng: &rng)
        return FeedItem(id: id, authorName: name, authorHandle: handle, location: city,
                        isCommunity: true, type: discipline, date: date, title: title, caption: caption,
                        statLine: stat, prBadge: pr, routeLatLon: route, mapStyle: style,
                        baseReactions: reactions)
    }

    /// A short, realistic-looking loop (~0.4–0.8 km) anchored on the city center (downtown = land), so
    /// the feed map frames a real place and the trace stays on streets, not out over water. (Without
    /// landcover data this is a small-radius + inland-anchor heuristic, not true land-snapping.)
    static func loopRoute(lat: Double, lon: Double, rng: inout SeededRNG) -> [[Double]] {
        let radius = rng.double(0.004, 0.0075)
        var pts: [[Double]] = []
        for step in 0...9 {
            let angle = Double(step) / 9 * 2 * .pi
            let wobble = rng.double(0.8, 1.05)
            pts.append([lat + sin(angle) * radius * wobble, lon + cos(angle) * radius * wobble])
        }
        return pts
    }

    private static func durStr(_ lo: Int, _ hi: Int, _ rng: inout SeededRNG) -> String {
        let m = rng.int(lo...hi)
        return m >= 60 ? "\(m / 60):\(String(format: "%02d", m % 60)):00" : "\(m):00"
    }

    private static func content(for discipline: WorkoutType, rng: inout SeededRNG) -> (String, String, String?) {
        let pr: String? = rng.int(0...6) == 0 ? rng.pick(prLabels) : nil
        switch discipline {
        case .run, .trailRun:
            return (rng.pick(runTitles), String(format: "%.1f mi · %@", rng.double(2, 14), durStr(20, 130, &rng)), pr)
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide:
            return (rng.pick(rideTitles), String(format: "%.1f mi · %@", rng.double(8, 60), durStr(35, 180, &rng)), pr)
        case .walk, .hike:
            return (rng.pick(walkTitles), String(format: "%.1f mi · %@", rng.double(1, 8), durStr(20, 120, &rng)), pr)
        case .strength, .crossfit, .hiit:
            let vol = rng.int(4...22) * 1000
            return (rng.pick(liftTitles), "\(vol.formatted()) lb · \(rng.int(8...26)) sets · \(durStr(35, 80, &rng))", pr)
        default:
            return (rng.pick(otherTitles), durStr(20, 70, &rng), pr)
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

    private static let bios = [
        "Hybrid athlete — lift heavy, move fast.","Marathoner in training. Coffee, then miles.",
        "Just here to beat yesterday.","Consistency over intensity.","Weekend warrior, weekday grinder.",
        "Chasing PRs and good sunrises.","Run streak in progress.","Strong is the goal."]
    private static let captions = [
        "Felt strong today.","Tough one but worth it.","Negative split the whole way.",
        "Legs heavy, heart full.","Dialed in.","Easy effort, big smile.","Beat my old time.","Showed up. That's the win."]
    private static let runTitles = ["Morning run","Tempo run","Long run","Easy miles","Sunrise tempo","Track session","Recovery jog"]
    private static let rideTitles = ["Morning ride","Hill repeats","Long ride","Gravel loop","Coffee ride","Interval ride"]
    private static let walkTitles = ["Recovery walk","Evening walk","Hike","Trail walk","Steps day"]
    private static let liftTitles = ["Push day","Pull day","Lower power","Upper hypertrophy","Full body","Leg day","Conditioning"]
    private static let otherTitles = ["Session","Flow","Pool intervals","Steady state","Open mat","Mobility"]
    private static let prLabels = ["5K PR","e1RM PR","Longest run","Fastest mile","Most volume","Longest ride"]
    /// Variety of basemaps across the feed (Strava-style "people use different maps").
    static let feedStyles: [MapStyleOption] = [.standard, .realistic, .streets, .outdoors, .dark, .satellite]
    private static let disciplines: [WorkoutType] = [.run,.run,.ride,.walk,.trailRun,.strength,.strength,.hiit,.swimming,.rowing,.yoga]
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
