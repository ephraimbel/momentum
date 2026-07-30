import Foundation
import UIKit

// (`CommunityPhotos` deleted 2026-07-30 — seeded posts carry no stock photos since the same-day
// reversal, and the enum had zero callers left. The `commphoto-*` asset blobs can leave the
// bundle whenever an app-size pass wants them.)

/// Generates a large, deterministic **Momentum community** (docs/SOCIAL-LAYER.md). Honest presence:
/// every generated athlete is clearly labeled community content in the UI (never a real stranger near
/// you). Deterministic (index-seeded) so the feed + globe are stable across launches. Athletes sit at
/// real cities — **US-majority** — with small jitter so globe dots land on cities (not the ocean), and
/// each GPS post carries a real short route + a varied map style so the feed shows real maps.
enum CommunityGenerator {
    /// Community scale (owner call 2026-07-29: "thousands across the globe" — feed, strip, and
    /// globe all read this same number, so they can never disagree). Deliberately NON-round: an
    /// even 3,000 reads as a planted figure. Identities are index-seeded, so growing the count
    /// appends new athletes without reshuffling anyone who already existed.
    static let count = 2_863

    static func generate(now: Date) -> [CommunityAthlete] {
        (0..<count).map { athlete(index: $0, now: now) }
    }

    private static func athlete(index i: Int, now: Date) -> CommunityAthlete {
        var rng = SeededRNG(i &* 2654435761)
        let first = rng.pick(firstNames)
        let last = rng.pick(lastNames)
        let name = "\(first) \(last)"
        let handle = "\(first.lowercased())\(last.prefix(1).lowercased())\(i + 10)"
        // ~78% US so the map is majority-US; real cities + tight jitter keep dots on land. The pick is
        // power-biased toward the front of the (roughly big-metro-first) list — real communities clump
        // in big cities; a flat pick made Boise as common as New York.
        let city = rng.int(0...99) < 78 ? pickBiased(usCities, &rng) : pickBiased(worldCities, &rng)
        let discipline = rng.pick(disciplines)

        // Bodies of work follow a power curve, not a flat spread: most people are early (a real
        // "from your first 5K" community has beginners), streaks cluster low with a thin long tail.
        // Uniform draws made every profile read mid-veteran with a fat streak — a generator tell.
        let workouts = 6 + Int(894 * pow(rng.double(0, 1), 2.4))
        let streak = Int(46 * pow(rng.double(0, 1), 3.2))
        // Lifetime distance follows the sport × the body of work (per-session km band × the sessions
        // that plausibly covered distance). A lifter/yogi with "4,200 km covered" was a fake tell.
        let perSessionKm: ClosedRange<Double> = switch discipline {
        case .run, .trailRun: 5...12
        case .ride: 18...45
        case .walk: 3...7
        case .swimming: 1.5...3.2
        case .rowing: 5...9
        default: 0...0                        // strength/HIIT/yoga: no meaningful distance
        }
        let distance = perSessionKm.upperBound == 0 ? 0
            : Double(workouts) * rng.double(perSessionKm.lowerBound, perSessionKm.upperBound) * rng.double(0.45, 0.8) * 1000

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
                            discipline: discipline, lat: city.lat, lon: city.lon, date: postDate,
                            now: now, rng: &postRng)

        return CommunityAthlete(
            handle: handle, name: name, location: city.name, bio: bio(for: discipline, rng: &rng),
            totalWorkouts: workouts, dayStreak: streak, totalDistanceM: distance,
            lat: lat, lon: lon, posts: [post])
    }

    /// "Athletes moving right now" for the wall's live strip — a deterministic time-of-day curve
    /// (twin peaks at 6–9 and 17–20, 3am near-quiet) with per-hour jitter, over the community's
    /// size. Stable within an hour, honest to the clock; real presence replaces it when the
    /// backend serves one.
    static func movingNow(now: Date = Date()) -> Int {
        let hour = Calendar.current.component(.hour, from: now)
        let day = Int(now.timeIntervalSince1970 / 86_400)
        let curve: [Double] = [0.010, 0.008, 0.006, 0.006, 0.012, 0.035,
                               0.075, 0.095, 0.085, 0.060, 0.045, 0.050,
                               0.055, 0.045, 0.040, 0.045, 0.060, 0.090,
                               0.105, 0.085, 0.055, 0.035, 0.022, 0.014]
        var rng = SeededRNG(day &* 24 &+ hour &* 7877)
        return max(3, Int(Double(count) * curve[hour] * rng.double(0.85, 1.15)))
    }

    /// Power-biased pick toward the front of a (roughly popularity-ordered) list — real communities
    /// clump; uniform picks read generated. One rng draw, like `pick`.
    private static func pickBiased<T>(_ pool: [T], _ rng: inout SeededRNG) -> T {
        pool[min(pool.count - 1, Int(Double(pool.count) * pow(rng.double(0, 1), 1.8)))]
    }

    /// A visited athlete's grid history — the older posts behind their most recent share, so their
    /// profile reads like a real training log (~10 weeks deep) rather than a single tile. Generated
    /// on demand per athlete (deterministic — seeded from the handle), NOT folded into the feed:
    /// the feed stays one-recent-post-per-athlete, exactly as before.
    static func historyPosts(handle: String, name: String, city: String, primary: WorkoutType,
                             count: Int, now: Date) -> [FeedItem] {
        var rng = SeededRNG(handle.utf8.reduce(11) { ($0 &* 131 &+ Int($1)) & 0x7FFF_FFFF })
        // A stable per-athlete discipline mix led by THEIR OWN sport — a swimmer's or lifter's grid
        // full of runs contradicted their feed post, bio, and discipline split (the loudest
        // non-runner fake tell). ~62% primary, the rest plausible cross-training for that sport.
        var date = now.addingTimeInterval(-Double(rng.int(30...90)) * 3600)
        return (0..<count).map { j in
            let roll = rng.int(0...99)
            let discipline: WorkoutType = roll < 62 ? primary
                : rng.pick(primary.isGPS ? [.strength, .walk, .hiit] : [.run, .walk, .strength])
            date = date.addingTimeInterval(-Double(rng.int(30...110)) * 3600)   // every 1–4½ days back
            // Unique, deterministic id-space far away from the feed posts' indices.
            let index = 500_000 + (handle.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }) * 100 + j
            return makePost(index: index, name: name, handle: handle, city: city,
                            discipline: discipline, lat: 0, lon: 0, date: date, now: now, rng: &rng)
        }
    }

    /// A brand-new post for `athlete`, dated moments ago — the pull-to-refresh pulse uses these so
    /// refreshing the page always surfaces something that just happened. Deterministic per
    /// (pulse, slot); ids live in their own space (8M+) far from feed (0+) and history (500k+) posts.
    static func freshPost(for athlete: CommunityAthlete, pulse: Int, slot: Int, now: Date) -> FeedItem {
        var rng = SeededRNG(pulse &* 48_611 &+ slot &* 7_129 &+ 977)
        // The fresh post leads with the athlete's OWN sport (like their grid) — a yogi suddenly
        // posting a run on refresh reads generated.
        let primary = athlete.primaryType
        let roll = rng.int(0...99)
        let discipline: WorkoutType = roll < 70 ? primary
            : rng.pick(primary.isGPS ? [.strength, .walk] : [.run, .walk])
        let date = now.addingTimeInterval(-rng.double(0.5, 6) * 60)
        return makePost(index: 8_000_000 + pulse * 50 + slot, name: athlete.name,
                        handle: athlete.handle, city: athlete.location ?? "Austin, TX",
                        discipline: discipline, lat: athlete.lat, lon: athlete.lon,
                        date: date, now: now, rng: &rng)
    }

    private static func makePost(index i: Int, name: String, handle: String, city: String,
                                 discipline: WorkoutType, lat: Double, lon: Double, date: Date,
                                 now: Date, rng: inout SeededRNG) -> FeedItem {
        let id = UUID(uuidString: "00000000-0000-0000-0001-\(String(format: "%012d", i))")!
        let caption = rng.int(0...2) == 0 ? nil : rng.pick(captions(for: discipline))
        let style = feedStyles[rng.int(0...(feedStyles.count - 1))]
        // A REAL street-following loop from the bundled Directions fetch — never a synthetic
        // shape over rooftops. If a city has no bundled loop, the post ships without a map
        // (an honest gap beats an obviously fake trace).
        //
        // Structured sessions (track reps, tempo, hills) and trail runs ship WITHOUT a map on
        // purpose: their titles claim terrain or a workout a downtown street loop would flatly
        // contradict ("Track night" over city blocks is the loudest fake tell), and real watch
        // posts from the track or the woods are mapless all the time — that's what honest looks
        // like in a feed.
        // ~8%: real feeds have the occasional watch-only interval post, but the WALL is a wall of
        // routes — at 14% two glyph tiles per screenful read as a pattern, not an exception.
        let structured = discipline == .run && rng.int(0...99) < 8
        let mapless = structured || discipline == .trailRun
        let loop = (discipline.isGPS && !mapless)
            ? CommunityRoutes.loop(city: city, discipline: discipline, rng: &rng) : nil
        let (title, stat, pr) = structured ? workoutContent(rng: &rng)
                                           : content(for: discipline, routeKm: loop?.km, rng: &rng)
        // NO stock photos on seeded posts (owner call 2026-07-30, reversing 2026-07-29): the
        // bundled Lorem Picsum shots read tacky next to real work, and a fake vista on a fake
        // post is the exact generator-tell this feed is engineered to avoid. Every seeded post
        // now leads with its own honest visual — the route, the muscle map, or the sport glyph
        // (the `CommunityPageMedia`/tile fallback). Real athletes' photo posts are untouched;
        // this only stops the seed from faking a camera roll.
        let photos: [Data] = []
        let coverPhoto = false
        let muscles = discipline.isStrengthStyle ? StrengthFeedMuscles.activation(forTitle: title, type: discipline) : nil
        let ai = rng.int(0...2) == 0 ? rng.pick(aiReads(for: discipline)) : nil
        // Respects follow a power law, not a flat 0–140 draw (that uniform spread was the strongest
        // distribution tell): most posts sit small with a thin popular tail, scaled by the author's
        // stable "audience" (handle-seeded), growing as the post ages (a 3-minute-old post hasn't
        // been seen yet), with a modest PR bump.
        var aud = SeededRNG(handle.utf8.reduce(17) { ($0 &* 37 &+ Int($1)) & 0x7FFF_FFFF })
        // Lively but still power-law (owner ask 2026-07-29): typical posts sit ~15–60 with a real
        // popular tail into the hundreds, and even a fresh post has been seen by SOMEONE (the
        // maturity floor) — a page of 2s and 3s read as a ghost town, not a community.
        let ceiling = 10 + 480 * pow(aud.double(0, 1), 2.2)
        let maturity = min(max(0, now.timeIntervalSince(date)) / 3600 / 24, 1)
        let reactions = Int(ceiling * max(maturity, 0.18) * (pr != nil ? 1.6 : 1.0) * rng.double(0.6, 1.1))
        return FeedItem(id: id, authorName: name, authorHandle: handle, location: city,
                        isCommunity: true, isPro: Self.isPro(handle: handle),
                        type: discipline, date: date, title: title, caption: caption,
                        statLine: stat, prBadge: pr, muscles: muscles, routeLatLon: loop?.pts, mapStyle: style,
                        baseReactions: reactions, photosData: photos, coverIsPhoto: coverPhoto,
                        aiRead: ai)
    }

    /// Whether a community member wears the purple Verified-Pro seal — the SAME checkmark a real
    /// Pro account shows (owner call 2026-07-30; replaces the old iridescent "Momentum" pill).
    /// Deterministic per handle so the byline, the pager, and the profile always agree, and
    /// deliberately not everyone: a wall where every single member is sealed reads as fake.
    /// Mixing constants differ from the audience RNG so Pro doesn't correlate with popularity.
    static func isPro(handle: String) -> Bool {
        let seed = handle.utf8.reduce(31) { ($0 &* 29 &+ Int($1)) & 0x7FFF_FFFF }
        return seed % 100 < 62
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
            // 4:40–7:10 /km ≈ 7:30–11:30 /mi — everyday-runner territory. A "long run" title only lands
            // on an actually-long distance (≥ ~9 mi); everything else is an always-true generic (time of
            // day / effort / place) so the title never contradicts the route or pace.
            let km = routeKm ?? rng.double(3, 12)
            return (rng.pick(km >= 14 ? longRunTitles : runTitles),
                    gpsStat(km: km, paceSecPerKm: rng.double(280, 430), rng: &rng), pr)
        case .trailRun:
            // Always mapless (makePost skips the street loop — no bundled trail geometry exists,
            // and "Singletrack miles" over downtown blocks was the loudest fake tell). Terrain is
            // carried by slower paces (5:35–8:00 /km) and a climb figure instead of a trace.
            let km = rng.double(6, 18)
            let climbFt = (Int(km * 0.6214 * rng.double(80, 320)) / 10) * 10
            return (rng.pick(trailTitles),
                    gpsStat(km: km, paceSecPerKm: rng.double(335, 480), rng: &rng)
                        + " · \(climbFt.formatted()) ft",
                    pr)
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
            // Volume derives from the sets (per-set load × sets, jittered) so the pair is always
            // plausible and never a round thousand — "22,000 lb · 8 sets" was an impossible tell.
            let sets = rng.int(9...24)
            let vol = sets * rng.int(520...1150) + rng.int(0...95)
            let seconds = rng.int(35 * 60...80 * 60)
            return (rng.pick(liftTitles), "\(vol.formatted()) lb · \(sets) sets · \(durationString(seconds: seconds))", pr)
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

    /// A structured session: track reps, tempo, hills. Total distance includes warmup and
    /// cooldown, and the overall pace sits between easy and race effort — a 45-minute "8×400"
    /// averaging 5:20/km is exactly what an interval night looks like on a watch.
    private static func workoutContent(rng: inout SeededRNG) -> (String, String, String?) {
        let pr = rng.int(0...7) == 0 ? rng.pick(["5K PR", "Fastest mile"]) : nil
        return (rng.pick(workoutTitles),
                gpsStat(km: rng.double(6, 13), paceSecPerKm: rng.double(275, 335), rng: &rng), pr)
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
    /// Bios match the athlete's sport — a lifter reading "Marathoner in training" (or a swimmer
    /// "Training for my first ultra") contradicted their own posts, the last uncoupled identity field.
    private static func bio(for discipline: WorkoutType, rng: inout SeededRNG) -> String {
        let pool: [String]
        switch discipline {
        case .run, .trailRun:
            pool = neutralBios + [
                "Marathoner in training. Coffee, then miles.", "Run streak in progress.",
                "Slow miles, big base.", "Training for my first ultra.", "Half marathon szn.",
                "Parent of two, runner of many miles.", "Physio by day, trail runner by weekend.",
                "Chasing PRs and good sunrises."]
        case .ride:
            pool = neutralBios + [
                "Cyclist. Hills are just downhills in waiting.", "Weekend century chaser.",
                "Two wheels, clear head.", "Coffee rides and long climbs."]
        case .strength, .crossfit, .hiit:
            pool = neutralBios + [
                "Strong is the goal.", "Lift heavy, move fast.", "Chasing PRs, not perfection.",
                "Progressive overload and patience.", "Gym rat with a stretching problem."]
        case .swimming:
            pool = neutralBios + [
                "Swimmer. The water always tells the truth.", "Laps before the world wakes up.",
                "Chlorine is my cologne."]
        case .rowing:
            pool = neutralBios + ["Erg every morning. Meters don't lie.", "2k trauma survivor."]
        case .walk, .hike:
            pool = neutralBios + [
                "Walking my way back to strong.", "Steps, sunlight, sanity.", "Trails over treadmills."]
        case .yoga:
            pool = neutralBios + [
                "Flow first, everything else after.", "Flexible plans, stiff hamstrings.",
                "Breathing is a workout too."]
        default:
            pool = neutralBios
        }
        return rng.pick(pool)
    }
    /// Sport-agnostic bios any athlete could carry.
    private static let neutralBios = [
        "Hybrid athlete. Lift heavy, move fast.", "Just here to beat yesterday.",
        "Consistency over intensity.", "Weekend warrior, weekday grinder.", "5am club.",
        "Back after an injury. Patient this time.", "Showing up is the whole plan.",
        "Training for life, not likes."]
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
        if discipline == .trailRun {
            return neutralCaptions + [
                "Roots and rocks the whole way.", "Climbed into the fog.", "Legs toast, worth it.",
                "Lost the trail twice lol", "Zero pace, all vert.", "The woods fixed my head.",
                "Hiking the ups, flying the downs."]
        }
        if discipline.isGPS {
            return neutralCaptions + [
                "Negative split the whole way.", "Legs heavy, heart full.", "Easy effort, big smile.",
                "Beat my old time.", "Perfect weather for it.", "Almost bailed at mile 2. Glad I didn't.",
                "First run in new shoes and yeah, believers now", "Humid one today 🥵",
                "Sunrise did all the work.", "Didn't want to. Did it anyway.",
                "Splits held on the last two.", "Legs knew what day it was."]
        }
        return neutralCaptions
    }
    private static let neutralCaptions = [
        "Felt strong today.", "Tough one but worth it.", "Dialed in.", "Showed up. That's the win.",
        "Not my best, still counts.", "Day 1 of the new block.", "Body said no, did it anyway."]
    // Titles are always-true generics (time of day, effort, place, or how people actually type a post)
    // rather than workout claims — a random street loop at an easy pace should never be labeled a
    // "Track session" or "Tempo run" it wasn't. Pools are big + varied in length so the feed doesn't
    // read as the same two-word title over and over.
    private static let runTitles = ["Morning run","Lunch run","Evening run","Night run","Easy miles","Recovery jog","Shakeout","Easy run","Base miles","Daily miles","Midweek miles","Neighborhood loop","Park loop","Riverside loop","Steady miles","Just some miles","Quick one before work","Got the miles in","Out the door early","Sunrise miles","A few easy ones","Around town"]
    private static let longRunTitles = ["Long run","Long one","Sunday long run","Weekend long run","Going long","Big miles","Long slow miles","The long one","Longest of the week"]
    private static let rideTitles = ["Morning ride","Evening ride","Long ride","Gravel loop","Coffee ride","Sunset spin","Recovery spin","Weekend ride","Lunch spin","Easy spin","Neighborhood loop","Base miles on the bike","Got out on the bike","Just spinning","Out for a roll"]
    private static let trailTitles = ["Trail run","Ridge loop","Singletrack miles","Dirt hour","Trail miles","Out on the trails","Woods run","Trail time","Switchbacks","Vert day","Fire road climb","Creek trail loop"]
    private static let workoutTitles = ["Track night","Track Tuesday","8×400 at the track","6×800 with the club","Mile repeats","400s and a cooldown","Tempo run","Tempo Thursday","Fartlek","Hill repeats","Speed day","Intervals","Workout Wednesday","5×1K","Strides and tempo"]
    private static let walkTitles = ["Recovery walk","Evening walk","Hike","Trail walk","Steps day","Nature walk","Out for a walk","Long walk"]
    private static let urbanWalkTitles = ["Morning walk","Evening walk","Recovery walk","Neighborhood loop","Steps day","Lunch walk","After dinner walk","Just a walk","Podcast walk","Around the block"]
    private static let liftTitles = ["Push day","Pull day","Leg day","Upper body","Lower body","Full body","Gym session","Strength day","Lifting","Quick lift","Accessory day","Back and bis","Chest day","Legs and core","Lower power","Upper hypertrophy"]
    private static let swimTitles = ["Pool intervals","Morning laps","Easy swim","Swim session","Lap swim","Recovery swim","Quick swim","Laps"]
    private static let rowTitles = ["Steady state","Erg intervals","Morning meters","Row session","Easy row","Quick erg","Meters in the bank","On the erg"]
    private static let yogaTitles = ["Flow","Mobility","Evening flow","Stretch and reset","Morning flow","Recovery yoga","Quick flow","Mobility work"]
    private static let otherTitles = ["Session","Steady state","Conditioning","Open mat","Quick session","Cross-training","Some work in"]
    /// Sample "Momentum read" lines shown in a post's reading view (clearly community/sample
    /// content, never presented as analysis of a real stranger). Matched to the sport — "consistent
    /// splits and a relaxed cadence" under a yoga flow or a lift was a fake tell — and the pools are
    /// deep enough that a scroll rarely repeats a line.
    private static func aiReads(for discipline: WorkoutType) -> [String] {
        if discipline.isStrengthStyle {
            return [
                "Volume landed right in the productive range. Pair it with an easy day tomorrow and the adaptation sticks.",
                "Load went up without the bar speed falling off. That is how strength is actually built.",
                "Smart session: the working sets stayed crisp and nothing bled into junk volume.",
                "The big lifts led and the accessories filled in behind them. Textbook structure.",
                "Same movements, slightly more weight than last time. Boring on purpose, and it works.",
                "Effort matched the plan. Nothing flashy, just another deposit in the consistency account.",
            ]
        }
        if discipline == .yoga {
            return [
                "Recovery work like this is what lets the hard days count. The engine grows at rest.",
                "A calm, unhurried session. This is the kind of maintenance that keeps training sustainable.",
                "Mobility now is injury insurance later. Quietly one of the most valuable sessions of the week.",
            ]
        }
        if discipline.isGPS || discipline == .swimming || discipline == .rowing {
            return [
                "A controlled effort. Heart rate stayed in the aerobic band the whole way, so this builds the engine without adding fatigue.",
                "Strong finish: the last third was the fastest, which is exactly how you want a steady session to end.",
                "Consistent splits and a relaxed cadence. This is the kind of repeatable session that compounds over months.",
                "Good intensity discipline: held back early, had something left to give late.",
                "Easy on paper, valuable in practice. Sessions like this are where the base actually comes from.",
                "The pace drifted less than one percent across the back half. That is real durability showing up.",
                "Effort matched the plan. Nothing flashy, just another deposit in the consistency account.",
            ]
        }
        return [
            "Effort matched the plan. Nothing flashy, just another deposit in the consistency account.",
            "Showing up on a day like this is the whole game. The fitness follows.",
        ]
    }
    /// Variety of basemaps across the feed (Strava-style "people use different maps"). No satellite —
    /// aerial imagery is off-brand and removed from the app's map choices.
    static let feedStyles: [MapStyleOption] = [.standard, .realistic, .streets, .outdoors, .dark]
    /// Repeats = weight. Run-DOMINANT (~65% run/trail, owner call 2026-07-29 — this is a running
    /// app and the wall should read like one): city runs with real street-loop maps, structured
    /// track/tempo sessions, trail runs with climb. The rest is the plausible cross-training a
    /// running community actually posts. Rowing rides on the featured @devonrows.
    private static let disciplines: [WorkoutType] = [
        .run, .run, .run, .run, .run, .run, .run, .run, .run, .run, .run,
        .trailRun,
        .strength, .strength, .ride, .ride, .walk, .swimming, .yoga]
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
