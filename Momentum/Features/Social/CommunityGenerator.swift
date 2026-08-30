import Foundation
import UIKit

// (`CommunityPhotos` deleted 2026-07-30 — seeded posts carry no stock photos since the same-day
// reversal, and the enum had zero callers left. The `commphoto-*` asset blobs can leave the
// bundle whenever an app-size pass wants them.)

/// Generates a large, deterministic **Momentum community** (docs/SOCIAL-LAYER.md). Honest presence:
/// every generated athlete is clearly labeled community content in the UI (never a real stranger near
/// you). Deterministic (index-seeded) so the feed + globe are stable across launches. Athletes live in
/// real TOWNS of real metros — **US-majority** — reverse-geocoded into `CommunityPlaces`, so a globe
/// dot is on land because a real place is there rather than because the jitter was kept tight, and
/// each GPS post carries a real short route + a varied map style so the feed shows real maps.
enum CommunityGenerator {
    /// Community scale (owner call 2026-07-29: "thousands across the globe" — feed, strip, and
    /// globe all read this same number, so they can never disagree). Deliberately NON-round: an
    /// even 3,000 reads as a planted figure. Identities are index-seeded, so growing the count
    /// appends new athletes without reshuffling anyone who already existed.
    static let count = 2_863

    #if DEBUG
    /// TEMPORARY split-timing probe for the 2026-08-29 load pass — how much of the directory build
    /// is the ledger walk and how much is materializing the wall card.
    nonisolated(unsafe) static var probeFoldMs = 0.0
    nonisolated(unsafe) static var probePostMs = 0.0
    static let probing = ProcessInfo.processInfo.arguments.contains("--community-perf")
    #endif

    static func generate(now: Date, clock: CommunityLedger.Clock) -> [CommunityAthlete] {
        // Handles are creative now, which means they can collide (two Mayas both landing on
        // "mayamiles"). A colliding athlete is rebuilt with a numeric tail — the same fix a real
        // signup flow makes. Seeded with the hand-curated eight so a generated athlete can never
        // steal a featured handle and shadow them in `CommunityDirectory.byHandle`.
        var used = featuredHandles
        var out: [CommunityAthlete] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let made = athlete(index: i, now: now, clock: clock)
            if used.insert(made.handle).inserted {
                out.append(made)
            } else {
                var n = 2
                var candidate = "\(made.handle)\(n)"
                while !used.insert(candidate).inserted { n += 1; candidate = "\(made.handle)\(n)" }
                out.append(athlete(index: i, now: now, clock: clock, handleOverride: candidate))
            }
        }
        return out
    }

    /// The hand-curated featured handles, literal so `generate` never re-enters CommunityDirectory.
    private static let featuredHandles: Set<String> = [
        "sub3maya", "bennettbuilt", "chenvelo", "priya.hybrid",
        "marcush2o", "vertsofia", "ergmornings", "amara_onestep"]

    /// A handle with some personality. Real communities are not "firstname + initial + number"
    /// 2,863 times over — that uniform shape was the loudest tell on every search result and
    /// byline. Deterministic per athlete (hashed from name + index, NOT from the sequential rng),
    /// mostly name-derived so search by name still finds people, with a thin tail of handles that
    /// are just a phrase the way real ones are.
    static func handle(first: String, last: String, discipline: WorkoutType, salt: Int) -> String {
        let f = first.lowercased()
        let l = last.lowercased()
        let li = String(l.prefix(1))
        let fi = String(f.prefix(1))
        var h = handleHash("\(f).\(l).\(salt)")
        func roll(_ n: Int) -> Int { h = h &* 6364136223846793005 &+ 1442695040888963407; return Int(h >> 33) % n }

        // Sport words, so a lifter never reads as a swimmer.
        let verbs: [String]
        let nouns: [String]
        switch discipline {
        case .run, .trailRun: verbs = ["runs", "jogs", "moves"]; nouns = ["miles", "splits", "strides", "pace", "kms"]
        case .ride:           verbs = ["rides", "spins"];        nouns = ["watts", "miles", "gears"]
        case .strength:       verbs = ["lifts", "trains"];       nouns = ["reps", "sets", "plates", "iron"]
        case .swimming:       verbs = ["swims"];                 nouns = ["laps", "meters"]
        case .walk:           verbs = ["walks"];                 nouns = ["steps", "miles"]
        case .rowing:         verbs = ["rows"];                  nouns = ["meters", "splits"]
        case .yoga, .pilates: verbs = ["flows"];                 nouns = ["mats", "breath"]
        default:              verbs = ["trains", "moves"];       nouns = ["reps", "sweat"]
        }
        let verb = verbs[roll(verbs.count)]
        let noun = nouns[roll(nouns.count)]
        // Two-digit tails that read like a person chose them (birth year, a race number), never a
        // sequential index.
        let yr = 82 + roll(23)
        let num = [7, 13, 21, 26, 42, 55, 88, 99, 100, 262][roll(10)]

        switch roll(18) {
        case 0:  return "\(f)\(verb)"
        case 1:  return "\(f)\(noun)"
        case 2:  return "\(f).\(l)"
        case 3:  return "\(f)\(l)"
        case 4:  return "\(f)_\(li)"
        case 5:  return "\(fi)\(l)"
        case 6:  return "\(f)\(yr)"
        case 7:  return "\(l)\(noun)"
        case 8:  return "\(verb)with\(f)"
        case 9:  return "\(f)\(String(l.prefix(3)))"
        case 10: return "its\(f)"
        case 11: return "\(f)\(num)"
        case 12: return "\(fi)\(li)\(num)"
        case 13: return "\(noun)and\(f)"
        case 14: return "\(f)\(l.suffix(2))\(roll(9))"
        case 15: return "the\(f)\(li)"
        case 16: return "\(f)_\(num)"
        default: return "\(f)\(li)\(yr)"
        }
    }

    /// FNV-1a — a hash that does not touch the athlete rng stream.
    private static func handleHash(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }

    private static func athlete(index i: Int, now: Date, clock: CommunityLedger.Clock,
                                handleOverride: String? = nil) -> CommunityAthlete {
        var rng = SeededRNG(i &* 2654435761)
        let first = rng.pick(firstNames)
        var last = rng.pick(lastNames)
        // "Cole" is in both pools, so one member of the directory was introducing herself as
        // "Cole Cole". Re-derived from a SEPARATE hash rather than by editing a pool: dropping an
        // entry would shift every later index and rename the whole community (the name draws are
        // the first two, and the handle hangs off them).
        if last == first {
            var n = 0
            repeat {
                last = lastNames[Int(handleHash("surname:\(first)\(i)\(n)") % UInt64(lastNames.count))]
                n += 1
            } while last == first && n < 8
        }
        let name = "\(first) \(last)"
        // ~78% US so the map is majority-US; real cities + tight jitter keep dots on land. The pick is
        // power-biased toward the front of the (roughly big-metro-first) list — real communities clump
        // in big cities; a flat pick made Boise as common as New York.
        let city = rng.int(0...99) < 78 ? pickBiased(usCities, &rng) : pickBiased(worldCities, &rng)
        let discipline = rng.pick(disciplines)
        // Handle derived from a SEPARATE hash, never from `rng`: the name/city/discipline draws are
        // load-bearing sequential state, and spending a draw here would reshuffle every athlete's
        // city and sport.
        let handle = handleOverride ?? Self.handle(first: first, last: last, discipline: discipline, salt: i)

        // Bodies of work follow a power curve, not a flat spread: most people are early (a real
        // "from your first 5K" community has beginners). This is now the ONLY body-of-work number
        // that is drawn — lifetime distance, the streak, the discipline split, the heatmap and the
        // trophy case all FOLD OUT of the ledger built from it, so they can never disagree with
        // each other or with the tiles the grid actually shows (owner report 2026-08-28: a profile
        // claiming 1,181 miles over a grid whose sessions summed to thirty).
        let workouts = 6 + Int(894 * pow(rng.double(0, 1), 2.4))
        #if DEBUG
        let _f0 = probing ? CFAbsoluteTimeGetCurrent() : 0
        #endif
        // Only the wall card is resolved here — a PREFIX of the ledger, not the whole career.
        // Folding all ~2,900 careers to fill `dayStreak` and `totalDistanceM` cost 611 ms at launch
        // and nothing on screen was waiting for either number: the profile refolds with `detail`
        // when it is opened. Those two are lazy now (`CommunityAthlete.dayStreak`), and the
        // session COUNT needs no walk at all — it is this draw.
        let lead = CommunityLedger.lead(handle: handle, primary: discipline, city: city.name,
                                        count: workouts, clock: clock)
        #if DEBUG
        if probing {
            probeFoldMs += (CFAbsoluteTimeGetCurrent() - _f0) * 1000
        }
        let _p0 = probing ? CFAbsoluteTimeGetCurrent() : 0
        defer { if probing { probePostMs += (CFAbsoluteTimeGetCurrent() - _p0) * 1000 } }
        #endif

        // **The two jitter draws stay exactly where they were.** They are draws six and seven of
        // the sequential stream the identity contract rests on; what changed on 2026-08-29 is only
        // what they are added TO. The athlete now lives in a real town of their metro
        // (`CommunityPlaces`, reverse-geocoded, so it is on land and has a real name) instead of
        // ±2 km from one of 65 downtown pins — but the town is chosen from a SEPARATE hash, the
        // same way `handle` is, so nobody's name, city, sport or body of work moved.
        let jitterLat = rng.double(-0.02, 0.02)
        let jitterLon = rng.double(-0.02, 0.02)
        let home = CommunityPlaces.home(metro: city.name, seed: handleHash("home:\(handle)"))
        let lat = (home?.lat ?? city.lat) + jitterLat
        let lon = (home?.lon ?? city.lon) + jitterLon
        // What they SAY. Their routes still come from the metro — a suburb has no bundled loop.
        let hometown = home?.display ?? city.name
        // Their feed post is a REAL ledger entry — the newest session in their own sport — so the
        // card on the wall is literally the tile at that index of their grid, never a thirteenth
        // workout invented on top of twelve. Content still rotates daily because the ledger is
        // anchored to today, so a returning user opens a new page every morning.
        let posts = lead.map {
            [post(index: i, name: name, handle: handle, city: city.name, place: hometown,
                  session: $0.session, slot: $0.index, now: now)]
        } ?? []

        return CommunityAthlete(
            handle: handle, name: name, location: hometown, metro: city.name,
            bio: bio(for: discipline, rng: &rng),
            totalWorkouts: workouts,
            lat: lat, lon: lon, posts: posts, primarySport: discipline)
    }

    /// Power-biased pick toward the front of a (roughly popularity-ordered) list — real communities
    /// clump; uniform picks read generated. One rng draw, like `pick`.
    private static func pickBiased<T>(_ pool: [T], _ rng: inout SeededRNG) -> T {
        pool[min(pool.count - 1, Int(Double(pool.count) * pow(rng.double(0, 1), 1.8)))]
    }

    /// A visited athlete's grid — one tile per ledger session, newest first. Materialized lazily in
    /// pages (`CommunityDirectory.gridPosts(for:limit:)`), because an athlete with 900 sessions has
    /// 900 tiles and only the first thirty are on screen. Each tile is derived from its OWN session
    /// and its own slot seed, so page two never depends on page one and scrolling far enough
    /// literally reaches every session the profile's totals count.
    static func gridPosts(handle: String, name: String, city: String, place: String,
                          sessions: [CommunitySession], from firstSlot: Int = 0,
                          now: Date) -> [FeedItem] {
        sessions.enumerated().map { offset, session in
            post(index: 0, name: name, handle: handle, city: city, place: place, session: session,
                 slot: firstSlot + offset, now: now)
        }
    }

    /// A brand-new session for `athlete`, minted moments ago — the pull-to-refresh pulse. It is a
    /// REAL session: `CommunityDirectory` records it against the athlete, so their grid, their
    /// session count, their lifetime distance and their streak all move with it rather than the
    /// wall showing a workout their own profile has never heard of. Deterministic per (pulse, slot).
    static func freshSession(for athlete: CommunityAthlete, pulse: Int, slot: Int,
                             now: Date) -> CommunitySession {
        var rng = SeededRNG(pulse &* 48_611 &+ slot &* 7_129 &+ 977)
        // The fresh session leads with the athlete's OWN sport — a yogi suddenly posting a run on
        // refresh reads generated.
        let primary = athlete.primaryType
        let type: WorkoutType = rng.int(0...99) < 70 ? primary
            : rng.pick(primary.isGPS ? [.strength, .walk] : [.run, .walk])
        let date = now.addingTimeInterval(-rng.double(0.5, 6) * 60)
        let kms = CommunityRoutes.loopKms(city: athlete.routeCity, discipline: type)
        var distanceM = 0.0
        var routePool: Int?
        if type.isGPS, type != .trailRun, !kms.isEmpty {
            let idx = rng.int(0...(kms.count - 1))
            routePool = idx
            distanceM = kms[idx] * 1000
        } else if type.isGPS {
            distanceM = rng.double(4, 12) * 1000
        }
        let durationS: Double = type.isGPS
            ? (distanceM / 1000) * rng.double(300, 420)
            : Double(rng.int(28 * 60...70 * 60))
        return CommunitySession(day: StreakCalculator.localDay(date), date: date, type: type,
                                distanceM: distanceM, durationS: durationS,
                                routePool: routePool, structured: false)
    }

    /// The card for a pulse session. Its id lives in its own space so it can never collide with a
    /// ledger tile's.
    static func freshPost(for athlete: CommunityAthlete, session: CommunitySession,
                          pulse: Int, slot: Int, now: Date) -> FeedItem {
        post(index: pulse &* 50 &+ slot, name: athlete.name, handle: athlete.handle,
             city: athlete.routeCity, place: athlete.location ?? athlete.routeCity,
             session: session, slot: slot, now: now, pulse: true)
    }

    /// Materializes one ledger session into a feed card: its real date, its real type, its real
    /// distance and duration, and — when the session traced one — the exact bundled street loop it
    /// traced. Nothing here re-draws a number the session already decided, which is what keeps a
    /// tile's stats equal to the ledger entry the profile totals counted.
    /// `city` is the METRO (the route key); `place` is the athlete's home town (what the card
    /// prints). They differ for every generated athlete — see `CommunityPlaces`.
    private static func post(index i: Int, name: String, handle: String, city: String, place: String,
                             session s: CommunitySession, slot: Int, now: Date,
                             pulse: Bool = false) -> FeedItem {
        // Per-(handle, slot) seed: a tile renders identically whether it arrived on page one or
        // page nine, and materializing a page never has to replay the pages before it.
        var rng = SeededRNG(handleSalt(handle) &+ slot &* 7919 &+ (pulse ? 104_729 : 0))
        let discipline = s.type
        let id = postID(handle: handle, slot: slot, pulse: pulse ? i : nil)
        let caption = rng.int(0...2) == 0 ? nil : rng.pick(captions(for: discipline))
        let style = feedStyles[rng.int(0...(feedStyles.count - 1))]
        // A REAL street-following loop from the bundled Directions fetch — never a synthetic
        // shape over rooftops. The ledger already chose which loop this session traced (and the
        // distance it credited the athlete IS that loop's true length), so the map and the numbers
        // agree by construction.
        //
        // Structured sessions (track reps, tempo, hills) and trail runs ship WITHOUT a map on
        // purpose: their titles claim terrain or a workout a downtown street loop would flatly
        // contradict ("Track night" over city blocks is the loudest fake tell), and real watch
        // posts from the track or the woods are mapless all the time — that's what honest looks
        // like in a feed.
        let loop: CommunityRoutes.Loop? = s.routePool.flatMap {
            CommunityRoutes.loop(city: city, discipline: discipline, slot: $0, offset: 0)
        }
        let (title, stat, pr) = content(for: s, rng: &rng)
        let date = s.date
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
        // A post's audience finds it fast and then tails off. The old `max(maturity, 0.18)` was a
        // step, not a curve: it pinned every post younger than four hours to the same sixth of its
        // ceiling, which both flattened the fresh end and (because comment volume is gated on
        // respects) left most of the page threadless. This is the same shape a real post follows —
        // steep early, still climbing all day — so an hour-old post has visibly more than a
        // minute-old one, and a full day's post has all of it.
        // **Three days to full, not one (2026-08-29).** The horizon has to match how fast the wall
        // actually turns over. It used to be a day, which was right when every wall post was an
        // hour or two old; now that the community posts only some of what it trains, four fifths of
        // the wall is older than a day and every one of those posts was pinned at its full ceiling.
        // A page where nothing is still filling up reads as loudly generated as one where nothing
        // has: the zero-comment share fell through the floor `CommentTests.threadVolumeIsSkewed`
        // holds, because thread volume is gated on respects.
        let age = min(max(0, now.timeIntervalSince(date)) / 3600 / 24 / 3, 1)
        let maturity = max(0.08, pow(age, 0.55))
        let reactions = Int(ceiling * maturity * (pr != nil ? 1.6 : 1.0) * rng.double(0.6, 1.1))
        return FeedItem(id: id, authorName: name, authorHandle: handle, location: place, metro: city,
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

    /// "X.X mi · T" straight off the session — the number the athlete's lifetime distance counted
    /// and the number their tile prints are the same number.
    ///
    /// Through `Formatters.distanceNumeral`, the SAME rounding the athlete's own posts use. A
    /// hand-rolled `%.1f` here meant a Friends wall could show "5.7 mi", "24.2 mi" and "4.45 mi"
    /// side by side, and the two-decimal one was always the real person's.
    private static func gpsStat(_ s: CommunitySession) -> String {
        "\(Formatters.distanceNumeral(s.distanceM / 1000 * 0.621371)) mi · \(durationString(seconds: Int(s.durationS)))"
    }

    /// A tile's stable identity: derived from (handle, slot) so the wall's card for an athlete and
    /// the tile their own grid draws at that slot are one post, not two. Pulse posts (which are
    /// newer than every ledger entry) take their own space above 9e11, and are identity-bound the
    /// same way — an id must describe WHOSE post it is, or engagement keyed to it lands on a
    /// stranger. Ledger ids stay under 2.7e11, so the two spaces cannot meet.
    private static func postID(handle: String, slot: Int, pulse: Int?) -> UUID {
        let n: Int64
        if let pulse {
            // FOLD THE HANDLE IN, exactly as the ledger branch below does. This read only
            // (pulse, slot) and never touched `handle`, even though it was right there in scope —
            // so two DIFFERENT athletes pulsed at the same slot minted the SAME UUID, inside a
            // single process, no relaunch required. Anything keyed to a post id then attached to
            // the wrong post: a comment appearing under a workout the athlete never opened, a
            // filled heart and a +1 on someone else's run (2026-08-29).
            //
            // The value stays inside [9e11, 10^12) so it remains above the ephemeral floor that
            // `CommunityPostID.isEphemeral` classifies on. That guard is still load-bearing and
            // must NOT be removed on the strength of this fix: identity-binding stops the
            // collision, but a pulse id is still minted from a per-process counter and still
            // means a different workout next launch, so engagement must not persist against one.
            let mixed = handleHash("pulse:\(handle):\(pulse):\(slot)") % 100_000_000_000
            n = 900_000_000_000 + Int64(mixed)
        } else {
            n = Int64(handleHash(handle) & 0xFFF_FFFF) * 1000 + Int64(min(max(slot, 0), 999))
        }
        // `%lld`, NOT `%d`: `%d` consumes a 32-bit CInt, so an id past Int32.max truncates and can
        // render NEGATIVE ("-1943132160"), which is not a UUID group — and the whole directory
        // would trap on the force-unwrap. Both branches stay under 10^12 so the value always fits
        // the final 12-character group. The fallback keeps a future arithmetic slip a cosmetic
        // duplicate-id bug instead of a crash on `CommunityDirectory.all()`.
        let clamped = min(max(n, 0), 999_999_999_999)
        return UUID(uuidString: "00000000-0000-0000-0001-\(String(format: "%012lld", clamped))")
            ?? UUID(uuidString: "00000000-0000-0000-0001-000000000000")!
    }

    /// A non-sequential per-handle salt for tile content (see `postID` for why content must not
    /// depend on the order pages were materialized in).
    private static func handleSalt(_ handle: String) -> Int {
        Int(handleHash("tile:\(handle)") & 0x7FFF_FFFF)
    }

    /// PR badges must match the sport AND the session. A "5K PR" on a 2.1 mile loop contradicts
    /// the stat line sitting an inch below it — the same class of thing as a profile whose miles
    /// don't match its grid — so every badge is gated on a distance that can actually contain it.
    private static func prLabel(for s: CommunitySession, rng: inout SeededRNG) -> String? {
        guard rng.int(0...6) == 0 else { return nil }
        let km = s.distanceM / 1000
        switch s.type {
        case .run, .trailRun:
            // A 5K PR needs a 5K in it; a mile PR needs a mile; "Longest run" is only honest on a
            // session that is actually long.
            var options: [String] = []
            if km >= 1.61 { options.append("Fastest mile") }
            if km >= 5 { options.append("5K PR") }
            if km >= 10 { options.append("10K PR") }
            if km >= 14 { options.append("Longest run") }
            return options.isEmpty ? nil : rng.pick(options)
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide:
            return km >= 40 ? "Longest ride" : nil
        case .hike:
            return km >= 8 ? "Longest hike" : nil
        case .strength, .crossfit: return rng.pick(["e1RM PR", "Most volume"])
        default: return nil
        }
    }

    /// The words over one session. Titles are drawn to fit what the session actually WAS — a "long
    /// run" title only lands on an actually-long one, a workout title only on a structured
    /// (mapless) session, a trail title only on a trail run — and every number printed is the
    /// session's own.
    private static func content(for s: CommunitySession, rng: inout SeededRNG) -> (String, String, String?) {
        let km = s.distanceM / 1000
        // A structured session: track reps, tempo, hills. It is always mapless (the ledger gave it
        // no loop), so the title can honestly claim the workout.
        if s.structured {
            // An interval night's PR still has to fit inside the session it sat in.
            var options: [String] = []
            if km >= 1.61 { options.append("Fastest mile") }
            if km >= 5 { options.append("5K PR") }
            let pr = (rng.int(0...7) == 0 && !options.isEmpty) ? rng.pick(options) : nil
            return (rng.pick(workoutTitles), gpsStat(s), pr)
        }
        let pr = prLabel(for: s, rng: &rng)
        switch s.type {
        case .run:
            // A "long run" title only lands on an actually-long distance (≥ ~8.7 mi); everything
            // else is an always-true generic (time of day / effort / place) so the title never
            // contradicts the route or the pace.
            return (rng.pick(km >= 14 ? longRunTitles : runTitles), gpsStat(s), pr)
        case .trailRun:
            // Always mapless (no bundled trail geometry exists, and "Singletrack miles" over
            // downtown blocks was the loudest fake tell). Terrain is carried by the slower pace
            // the ledger gave it and a climb figure instead of a trace.
            let climbFt = (Int(km * 0.6214 * rng.double(80, 320)) / 10) * 10
            return (rng.pick(trailTitles), gpsStat(s) + " · \(climbFt.formatted()) ft", pr)
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide:
            return (rng.pick(rideTitles), gpsStat(s), pr)
        case .walk, .hike:
            // Hike/trail titles only WITHOUT a route map — the bundled loops trace city streets,
            // and "Trail walk" over downtown blocks reads fake.
            return (rng.pick(s.routePool == nil ? walkTitles : urbanWalkTitles), gpsStat(s), pr)
        case .strength, .crossfit, .hiit:
            // Volume derives from the sets (per-set load × sets, jittered) so the pair is always
            // plausible and never a round thousand — "22,000 lb · 8 sets" was an impossible tell.
            let sets = rng.int(9...24)
            let vol = sets * rng.int(520...1150) + rng.int(0...95)
            return (rng.pick(liftTitles),
                    "\(vol.formatted()) lb · \(sets) sets · \(durationString(seconds: Int(s.durationS)))", pr)
        default:
            // Timed sports get their OWN titles — "Pool intervals" on a yoga post is a fake tell.
            let titles: [String] = switch s.type {
            case .swimming: swimTitles
            case .rowing: rowTitles
            case .yoga: yogaTitles
            default: otherTitles
            }
            return (rng.pick(titles), durationString(seconds: Int(s.durationS)), pr)
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

    /// Every metro the community draws from, in list order. `scripts/fetch_community_places.py`
    /// parses these same two arrays out of this file, so `CommunityPlaces` can never cover a
    /// different set of cities than the generator picks from
    /// (`CommunityPlacesTests.everyMetroTheCommunityDrawsFromHasRealTowns`).
    static var seedMetros: [String] { usCities.map(\.name) + worldCities.map(\.name) }

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
    /// running community actually posts. Rowing rides on the featured rower (@ergmornings).
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
            // Mint the SESSION first and record it against the athlete: a pulse is someone
            // finishing a workout, so it has to land in their ledger too. Otherwise the wall would
            // show a session their own profile has never counted — the exact class of drift this
            // whole ledger exists to make impossible.
            let session = CommunityGenerator.freshSession(for: pick, pulse: pulse, slot: slot, now: now)
            let item = CommunityGenerator.freshPost(for: pick, session: session,
                                                    pulse: pulse, slot: slot, now: now)
            CommunityDirectory.recordPulse(session, item: item, for: pick.handle)
            fresh.append(item)
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
