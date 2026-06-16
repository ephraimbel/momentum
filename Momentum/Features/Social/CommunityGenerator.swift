import Foundation

/// Generates a large, deterministic **Momentum community** (docs/SOCIAL-LAYER.md). Honest presence:
/// every generated athlete is clearly labeled community content in the UI (never a real stranger near
/// you). Deterministic (index-seeded) so the feed + globe are stable across launches. Replaced by
/// real network athletes once Supabase is configured.
enum CommunityGenerator {
    /// How many athletes to seed beyond the hand-curated featured set.
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
        let city = rng.pick(cities)
        let discipline = rng.pick(disciplines)

        let workouts = rng.int(40...900)
        let streak = rng.int(0...44)
        let distance = Double(rng.int(120...9800)) * 1000

        let postDate = now.addingTimeInterval(-rng.double(0.3, 96) * 3600)   // last ~4 days
        let post = makePost(index: i, handle: handle, name: name, city: city.name,
                            discipline: discipline, date: postDate, rng: &rng)

        return CommunityAthlete(
            handle: handle, name: name, location: city.name,
            bio: rng.pick(bios),
            totalWorkouts: workouts, dayStreak: streak, totalDistanceM: distance,
            // Wide regional scatter around the home city (≈±4°) so ~950 athletes read as ~950 distinct
            // dots across the world rather than 36 overlapping blobs — and it fuzzes location further.
            lat: max(-78, min(80, city.lat + rng.double(-4, 4))), lon: city.lon + rng.double(-4.5, 4.5),
            posts: [post])
    }

    private static func makePost(index i: Int, handle: String, name: String, city: String,
                                 discipline: WorkoutType, date: Date, rng: inout SeededRNG) -> FeedItem {
        let id = UUID(uuidString: "00000000-0000-0000-0001-\(String(format: "%012d", i))")!
        let reactions = rng.int(0...140)
        let caption = rng.int(0...2) == 0 ? nil : rng.pick(captions)
        let route: [CGPoint]? = discipline.isGPS ? rng.pick(routeShapes) : nil
        let (title, stat, pr) = content(for: discipline, rng: &rng)
        return FeedItem(id: id, authorName: name, authorHandle: handle, location: city,
                        isCommunity: true, type: discipline, date: date, title: title, caption: caption,
                        statLine: stat, prBadge: pr, routeNorm: route, baseReactions: reactions)
    }

    private static func durStr(_ lo: Int, _ hi: Int, _ rng: inout SeededRNG) -> String {
        let m = rng.int(lo...hi)
        return m >= 60 ? "\(m / 60):\(String(format: "%02d", m % 60)):00" : "\(m):00"
    }

    private static func content(for discipline: WorkoutType, rng: inout SeededRNG) -> (String, String, String?) {
        let pr: String? = rng.int(0...6) == 0 ? rng.pick(prLabels) : nil
        switch discipline {
        case .run, .trailRun:
            let mi = rng.double(2, 14)
            return (rng.pick(runTitles), String(format: "%.1f mi · %@", mi, durStr(20, 130, &rng)), pr)
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide:
            let mi = rng.double(8, 60)
            return (rng.pick(rideTitles), String(format: "%.1f mi · %@", mi, durStr(35, 180, &rng)), pr)
        case .walk, .hike:
            let mi = rng.double(1, 8)
            return (rng.pick(walkTitles), String(format: "%.1f mi · %@", mi, durStr(20, 120, &rng)), pr)
        case .strength, .crossfit, .hiit:
            let vol = rng.int(4...22) * 1000
            return (rng.pick(liftTitles), "\(vol.formatted()) lb · \(rng.int(8...26)) sets · \(durStr(35, 80, &rng))", pr)
        default:
            return (rng.pick(otherTitles), durStr(20, 70, &rng), pr)
        }
    }

    // MARK: Pools
    private static let firstNames = ["Maya","Theo","Lin","Priya","Marcus","Sofia","Devon","Amara","Jamal","Nina","Owen","Yuki","Diego","Hana","Liam","Zara","Noah","Aisha","Caleb","Mei","Andre","Ravi","Elena","Kofi","Ines","Tomas","Leila","Sven","Rosa","Kai","Bianca","Omar","Freya","Hugo","Tara","Mateo","Ada","Joon","Carmen","Felix","Nadia","Pablo","Greta","Sami","Lucia","Dario","Mira","Theo","Esme","Ravi"]
    private static let lastNames = ["Rivera","Bennett","Chen","Nair","Hill","Alvarez","Kim","Okafor","Reed","Petrov","Lowe","Sato","Mendez","Park","Walsh","Haddad","Cohen","Diallo","Brooks","Tan","Costa","Iyer","Novak","Mensah","Roca","Berg","Faraj","Lindqvist","Santos","Wu"]
    private static let cities: [(name: String, lat: Double, lon: Double)] = [
        ("Austin, TX",30.27,-97.74),("New York, NY",40.71,-74.01),("Portland, OR",45.52,-122.68),
        ("Miami, FL",25.76,-80.19),("Boulder, CO",40.01,-105.27),("Seattle, WA",47.61,-122.33),
        ("Chicago, IL",41.88,-87.63),("London",51.51,-0.13),("Paris",48.86,2.35),("Berlin",52.52,13.40),
        ("Tokyo",35.68,139.69),("Sydney",-33.87,151.21),("Toronto",43.65,-79.38),("Cape Town",-33.92,18.42),
        ("Mexico City",19.43,-99.13),("São Paulo",-23.55,-46.63),("Mumbai",19.08,72.88),("Nairobi",-1.29,36.82),
        ("Madrid",40.42,-3.70),("Stockholm",59.33,18.06),("Singapore",1.35,103.82),("Denver, CO",39.74,-104.99),
        ("Vancouver",49.28,-123.12),("Dublin",53.35,-6.26),("Lisbon",38.72,-9.14),("Amsterdam",52.37,4.90),
        ("San Francisco, CA",37.77,-122.42),("Los Angeles, CA",34.05,-118.24),("Boston, MA",42.36,-71.06),
        ("Auckland",-36.85,174.76),("Oslo",59.91,10.75),("Rome",41.90,12.50),("Seoul",37.57,126.98),
        ("Buenos Aires",-34.60,-58.38),("Cairo",30.04,31.24),("Bangkok",13.76,100.50)]
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
    private static let routeShapes: [[CGPoint]] = [
        [CGPoint(x:0.2,y:0.5),CGPoint(x:0.35,y:0.25),CGPoint(x:0.6,y:0.2),CGPoint(x:0.8,y:0.4),CGPoint(x:0.75,y:0.7),CGPoint(x:0.5,y:0.8),CGPoint(x:0.3,y:0.72),CGPoint(x:0.2,y:0.5)],
        [CGPoint(x:0.1,y:0.7),CGPoint(x:0.3,y:0.55),CGPoint(x:0.45,y:0.62),CGPoint(x:0.6,y:0.4),CGPoint(x:0.78,y:0.45),CGPoint(x:0.9,y:0.25)],
        [CGPoint(x:0.15,y:0.6),CGPoint(x:0.25,y:0.3),CGPoint(x:0.5,y:0.15),CGPoint(x:0.8,y:0.3),CGPoint(x:0.85,y:0.6),CGPoint(x:0.65,y:0.85),CGPoint(x:0.35,y:0.82),CGPoint(x:0.18,y:0.7),CGPoint(x:0.15,y:0.6)],
        [CGPoint(x:0.2,y:0.3),CGPoint(x:0.4,y:0.45),CGPoint(x:0.55,y:0.35),CGPoint(x:0.7,y:0.55),CGPoint(x:0.85,y:0.5)]]
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
