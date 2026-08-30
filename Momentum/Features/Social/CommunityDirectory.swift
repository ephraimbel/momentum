import Foundation

/// A seeded **Momentum community** athlete — a curated/official sample profile with its posts
/// (docs/SOCIAL-LAYER.md). Honest by design: clearly community content, never fake strangers. Both
/// the feed (their posts) and their profile page read from this one source. Replaced by real network
/// profiles once Supabase is configured.
struct CommunityAthlete: Identifiable, Sendable, Hashable {
    let handle: String
    let name: String
    /// What they SAY they are from — a real town of their metro ("Buda, TX", "Neukölln"), picked
    /// from `CommunityPlaces`. Never a route key: see `metro`.
    let location: String?
    /// The metro their bundled street loops come from ("Austin, TX", "Berlin").
    ///
    /// A suburb has no loop of its own, so `CommunityRoutes` and `CommunityLedger` stay keyed by
    /// the metro while the athlete's home town moved off downtown (2026-08-29). nil for real
    /// network athletes and the hand-curated featured eight, whose `location` IS a metro.
    let metro: String?
    let bio: String
    let totalWorkouts: Int
    /// Real network athletes carry their own aggregates. nil for the seeded community, whose
    /// streak and lifetime distance are FOLDS OVER A WHOLE CAREER — see `dayStreak` below.
    private let storedStreak: Int?
    private let storedDistanceM: Double?
    let lat: Double            // approximate home location for the globe (fuzzed — city-level)
    let lon: Double
    let posts: [FeedItem]
    /// The sport this athlete actually trains, independent of what their newest post happens to
    /// be. Their feed card is a real ledger entry now, and a runner's newest session is sometimes
    /// the gym — without this, one cross-training day would re-read their whole identity (bio,
    /// chips, grid mix, lifetime hero) as a lifter's. nil for real network athletes, who fall back
    /// to their newest post exactly as before.
    var primarySport: WorkoutType? = nil
    /// A hand-curated newest session (the featured eight each have one real, written post). The
    /// ledger walk pins it as entry 0 and builds the rest of their career behind it, so their
    /// totals count the post the wall shows.
    var ledgerLead: CommunitySession? = nil
    /// Real athletes (Supabase) carry their avatar; seeded community renders a bundled synthetic face.
    var avatarData: Data? = nil
    /// True for the seeded "Momentum community" (whose body-of-work is deterministic sample
    /// content); false for real network athletes — their profile shows only real data.
    var isSample: Bool = true
    var id: String { handle }

    /// Their current streak, and their lifetime distance.
    ///
    /// **Computed, not stored, for the seeded community.** Both are folds over a whole training
    /// career, and filling them for all ~2,900 athletes at launch cost 611 ms of a cold Community
    /// open while nothing on screen wanted either number — the wall shows neither, and a visited
    /// profile re-folds anyway (`CommunityDirectory.lifetime(for:)`, which also counts pulse
    /// sessions). The fold happens on the first read now, memoized per handle. `totalWorkouts`
    /// stays stored because it costs nothing: it IS the drawn session count, and the walk emits
    /// exactly that many.
    var dayStreak: Int { storedStreak ?? CommunityLedgerMemo.lifetime(of: self).streakDays }
    var totalDistanceM: Double { storedDistanceM ?? CommunityLedgerMemo.lifetime(of: self).distanceM }

    /// **The key every route and ledger lookup must use** — the metro, falling back to `location`
    /// for athletes who have no separate one, and to the bundled default for those with neither.
    /// Passing `location` instead misses every bundled loop and silently strips the maps off the
    /// whole community (`CommunityPlacesTests.routesAreStillKeyedByTheMetroNotTheTown`).
    var routeCity: String { metro ?? location ?? CommunityLedger.fallbackCity }

    /// Explicit so the two aggregates can be OMITTED by the seeded community while real network
    /// athletes keep passing their own (`RemoteFeedStore`) — the labels and order are unchanged.
    init(handle: String, name: String, location: String?, metro: String? = nil, bio: String,
         totalWorkouts: Int, dayStreak: Int? = nil, totalDistanceM: Double? = nil,
         lat: Double, lon: Double, posts: [FeedItem],
         primarySport: WorkoutType? = nil, ledgerLead: CommunitySession? = nil,
         avatarData: Data? = nil, isSample: Bool = true) {
        self.handle = handle
        self.name = name
        self.location = location
        self.metro = metro
        self.bio = bio
        self.totalWorkouts = totalWorkouts
        self.storedStreak = dayStreak
        self.storedDistanceM = totalDistanceM
        self.lat = lat
        self.lon = lon
        self.posts = posts
        self.primarySport = primarySport
        self.ledgerLead = ledgerLead
        self.avatarData = avatarData
        self.isSample = isSample
    }

    /// The seeded athlete's bundled synthetic-face asset (deterministic per name); nil for real
    /// network athletes. See `CommunityAvatars`.
    var communityAvatarAsset: String? { isSample ? CommunityAvatars.assetName(forHandle: handle) : nil }
    /// The hash-assigned preset look for face-less community athletes (see `CommunityAvatars.preset`).
    var communityPreset: AvatarPreset? { isSample ? CommunityAvatars.preset(forHandle: handle) : nil }
}

enum CommunityDirectory {
    // Generated once per launch (≈950 athletes) so the feed + globe are stable and not rebuilt on
    // each access. Featured (hand-curated) athletes lead; the generated community fills out the
    // rest. Identities are launch-stable; post content rotates daily (CommunityGenerator).
    private static let baseDate = Date()
    /// The community's ONE clock. Every ledger in the directory is folded against this instant, so
    /// an athlete's totals (computed at launch) and their grid (materialized when you open them)
    /// are always reading the same training history — re-deriving against a later `Date()` would
    /// let a session appear mid-session and put the count back out of step with the tiles.
    static let seedClock = CommunityLedger.Clock(baseDate)
    private static let cached: [CommunityAthlete] = {
        #if DEBUG
        let _t0 = CFAbsoluteTimeGetCurrent()
        #endif
        let out = featured(now: baseDate, clock: seedClock)
            + CommunityGenerator.generate(now: baseDate, clock: seedClock)
        #if DEBUG
        CommunityBuildProbe.dump(out, since: _t0, now: baseDate)
        #endif
        return out
    }()

    /// The community, built once per process against the launch instant.
    ///
    /// **It takes no `now`, on purpose.** It used to declare one and never read it — a parameter
    /// that silently ignores its argument is worse than none, because a caller wanting a
    /// reproducible community would have believed it got one. Nothing in the tree passed it. A
    /// test that needs a community that does not move must say so: `fixture(now:)`.
    static func all() -> [CommunityAthlete] { cached }

    #if DEBUG
    /// The community rebuilt at a FIXED instant — uncached, for tests that measure a
    /// DISTRIBUTION rather than one athlete's numbers.
    ///
    /// `cached` is anchored to the launch clock, and a seeded post's respects grow with its own
    /// age (`CommunityGenerator.post`, the three-day maturity curve), so every fold over
    /// `baseReactions` slides with the wall clock: `CommentTests.threadVolumeIsSkewedNotFlat`
    /// measured 0.34936, 0.34901 then 0.34866 across three runs ten minutes apart — a straight
    /// line in time, not flake. A bound on a distribution has to be read off a community that
    /// stands still.
    ///
    /// Read only what the build itself produced (`posts`, `location`, `totalWorkouts`). Anything
    /// that folds through `CommunityDirectory.gridPosts(for:)` / `lifetime(for:)` or
    /// `CommunityLedgerMemo` is measured against `seedClock`, the LAUNCH instant, so mixing the
    /// two would compare two different todays — call `CommunityLedger` directly with the same
    /// `now` instead.
    static func fixture(now: Date) -> [CommunityAthlete] {
        let clock = CommunityLedger.Clock(now)
        return featured(now: now, clock: clock) + CommunityGenerator.generate(now: now, clock: clock)
    }
    #endif

    // Handle → athlete index, built once with the directory. `athlete(handle:)` was a linear scan
    // over all ~950 athletes; follow lists resolve dozens of handles per render, which multiplied
    // into tens of thousands of string compares (perf audit 2026-08-16).
    private static let byHandle: [String: CommunityAthlete] =
        Dictionary(cached.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })

    /// The hand-curated featured athletes (lead the feed; richer copy + globe spread).
    ///
    /// Their totals used to be hand-written too — Maya claimed 4,120 km and a 21-day streak that
    /// nothing behind her profile could account for. Now only the *persona* is written (who they
    /// are, what they posted, how big their career is); the distance, the streak, the discipline
    /// split, the heatmap and the awards are folded out of a ledger led by the very post below, so
    /// the featured eight satisfy exactly the same invariants as the other 2,863.
    static func featured(now: Date = Date(), clock: CommunityLedger.Clock? = nil) -> [CommunityAthlete] {
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        /// GPS posts take a REAL bundled loop nearest `targetKm` and derive their stat from its
        /// true length at `paceSecPerKm` (the map and the numbers agree); non-GPS posts pass a
        /// literal `stat` plus the `km`/`seconds` that stat states, so the ledger credits them the
        /// distance and time their own card prints.
        func post(_ n: Int, _ a: CommunityAuthor, _ type: WorkoutType, _ when: Date, _ title: String,
                  _ caption: String?, _ stat: String = "", city: String? = nil,
                  targetKm: Double = 8, paceSecPerKm: Double = 340, mapless: Bool = false,
                  litKm: Double = 0, litSeconds: Double = 0,
                  pr: String? = nil, reactions: Int = 0, ai: String? = nil)
        -> (item: FeedItem, session: CommunitySession) {
            var rng = SeededRNG(n &* 99_173)
            // `mapless` = the generator's honesty rule for the hand-curated voices too: a title
            // that claims a workout or terrain ("tempo", "Hill repeats", a trail) must never sit
            // over a downtown street loop (CommunityContentAuditTests trips otherwise).
            let loop = (type.isGPS && !mapless)
                ? (city ?? a.location).flatMap { CommunityRoutes.loop(city: $0, discipline: type, nearestKm: targetKm) }
                : nil
            var seconds = litSeconds
            let statLine = loop.map {
                seconds = ($0.km * paceSecPerKm + rng.double(0, 59)).rounded(.down)
                return "\(Formatters.distanceNumeral($0.km * 0.621371)) mi · "
                    + CommunityGenerator.durationString(seconds: Int(seconds))
            } ?? stat
            let muscles = type.isStrengthStyle ? StrengthFeedMuscles.activation(forTitle: title, type: type) : nil
            let style = CommunityGenerator.feedStyles[n % CommunityGenerator.feedStyles.count]
            // The seal the profile draws for this handle, so a featured athlete isn't Verified on
            // their profile and unverified on their own byline — the two surfaces a curious user
            // visits back to back.
            // The featured eight are written personas: their `location` IS a metro, so it doubles
            // as the route/season key here (the generated community carries the two separately).
            let item = FeedItem(id: pid(n), authorName: a.name, authorHandle: a.handle,
                                location: a.location, metro: city ?? a.location,
                                isCommunity: true, isPro: CommunityGenerator.isPro(handle: a.handle),
                                type: type, date: when, title: title, caption: caption,
                                statLine: statLine, prBadge: pr, muscles: muscles, routeLatLon: loop?.pts,
                                mapStyle: style, baseReactions: reactions, aiRead: ai)
            let session = CommunitySession(day: StreakCalculator.localDay(when), date: when, type: type,
                                           distanceM: (loop?.km ?? litKm) * 1000, durationS: seconds,
                                           routePool: nil, structured: false)
            return (item, session)
        }

        /// Assembles one featured athlete: the written persona, their curated post pinned as the
        /// newest ledger entry, and every lifetime number folded out of the ledger behind it.
        func athlete(_ a: CommunityAuthor, bio: String, sessions: Int, sport: WorkoutType,
                     lat: Double, lon: Double,
                     post p: (item: FeedItem, session: CommunitySession)) -> CommunityAthlete {
            // No walk here either: their curated post IS ledger entry 0, the session count is the
            // written one, and the streak/distance fold when someone opens them.
            CommunityAthlete(
                handle: a.handle, name: a.name, location: a.location, bio: bio,
                totalWorkouts: sessions, lat: lat, lon: lon, posts: [p.item],
                primarySport: sport, ledgerLead: p.session)
        }

        let maya = CommunityAuthor("sub3maya", "Maya Rivera", "Austin, TX")
        let theo = CommunityAuthor("bennettbuilt", "Theo Bennett", nil)
        let lin = CommunityAuthor("chenvelo", "Lin Chen", "Portland, OR")
        let priya = CommunityAuthor("priya.hybrid", "Priya N.", nil)
        let marcus = CommunityAuthor("marcush2o", "Marcus Hill", "Miami, FL")
        let sofia = CommunityAuthor("vertsofia", "Sofia A.", "Boulder, CO")
        let devon = CommunityAuthor("ergmornings", "Devon K.", nil)
        let amara = CommunityAuthor("amara_onestep", "Amara O.", "Seattle, WA")

        return [
            athlete(maya, bio: "Marathoner chasing a sub-3. Coffee, then miles.",
                sessions: 312, sport: .run, lat: 30.27, lon: -97.74,
                post: post(1, maya, .run, ago(1.5), "Sunrise miles", "Negative split the whole way. Felt strong.", city: "Austin, TX", targetKm: 10, paceSecPerKm: 290, pr: "5K PR", reactions: 42, ai: "A textbook negative split. The back half was quicker at the same heart rate, which means real aerobic fitness is showing up, not just a good day.")),
            athlete(theo, bio: "Strength coach. Big believer in boring consistency.",
                sessions: 540, sport: .strength, lat: 40.78, lon: -73.97,
                post: post(2, theo, .strength, ago(4), "Lower power", "Squats moving well at 3 plates.", "12,400 lb · 18 sets · 1:02:40", litSeconds: 3_760, pr: "Squat e1RM PR", reactions: 67, ai: "Tonnage up with the same RPE. The new e1RM is earned, not a fluke. Hold this volume for a week before pushing load again.")),
            athlete(lin, bio: "Cyclist. Hills are just downhills in waiting.",
                sessions: 268, sport: .ride, lat: 45.52, lon: -122.64,
                post: post(3, lin, .ride, ago(7), "Hill repeats", nil, "24.2 mi · 1:30:21", mapless: true, litKm: 38.95, litSeconds: 5_421, reactions: 18)),
            athlete(priya, bio: "Hybrid athlete. Lift heavy, move fast.",
                sessions: 190, sport: .hiit, lat: 51.51, lon: -0.13,
                post: post(4, priya, .hiit, ago(11), "Conditioning", "Quick and brutal.", "22:14", litSeconds: 1_334, reactions: 9)),
            athlete(marcus, bio: "Swimmer. The water always tells the truth.",
                sessions: 221, sport: .swimming, lat: 25.77, lon: -80.25,
                post: post(5, marcus, .swimming, ago(20), "Pool intervals", "2km steady.", "38:42", litSeconds: 2_322, reactions: 14)),
            athlete(sofia, bio: "Trail runner. Higher is better.",
                sessions: 156, sport: .trailRun, lat: 40.01, lon: -105.27,
                post: post(6, sofia, .trailRun, ago(28), "Mesa loop", "Big climb, bigger views.", "8.1 mi · 1:14:45 · 1,350 ft", mapless: true, litKm: 13.03, litSeconds: 4_485, pr: "Longest run", reactions: 51)),
            athlete(devon, bio: "Erg every morning. Meters don't lie.",
                sessions: 410, sport: .rowing, lat: 41.88, lon: -87.63,
                post: post(7, devon, .rowing, ago(33), "Steady state", nil, "40:19", litSeconds: 2_419, reactions: 7)),
            athlete(amara, bio: "Walking my way back to strong. One step at a time.",
                sessions: 88, sport: .walk, lat: 47.62, lon: -122.31,
                post: post(8, amara, .walk, ago(46), "Recovery walk", "Easy day, clear head.", targetKm: 5, paceSecPerKm: 570, reactions: 23)),
        ]
    }

    static func athlete(handle: String, now: Date = Date()) -> CommunityAthlete? {
        byHandle[handle]
    }

    // MARK: The visited profile's grid + lifetime — both read the same ledger

    /// Materialized grid tiles per handle: the longest PAGE built so far, newest first. Profiles
    /// open instantly on revisit, and a 900-session athlete never costs 900 feed cards to open.
    @MainActor private static var gridCache: [String: [FeedItem]] = [:]
    @MainActor private static var lifetimeCache: [String: CommunityLifetime] = [:]
    /// Sessions minted by the pull-to-refresh pulse — real sessions, so they count.
    @MainActor private static var pulseSessions: [String: [(session: CommunitySession, item: FeedItem)]] = [:]
    /// Visit order, so the two caches stay bounded on a long browse.
    @MainActor private static var cacheOrder: [String] = []
    private static let cacheLimit = 24

    /// How many tiles a profile materializes at a time. The grid is three across, so this is ten
    /// rows: more than a screenful, few enough that opening a veteran's profile is as cheap as
    /// opening a beginner's.
    static let gridPageSize = 30

    /// The posts shown on a visited SAMPLE athlete's profile grid — one tile per ledger session,
    /// newest first, materialized in pages as the athlete scrolls. Scrolling far enough literally
    /// reaches every session their profile totals count, which is the whole point: the grid IS the
    /// body of work, not a sample of it. Real athletes never come through here; their grids show
    /// only what they actually shared.
    @MainActor
    static func gridPosts(for athlete: CommunityAthlete, limit: Int = gridPageSize,
                          now: Date = Date()) -> [FeedItem] {
        guard athlete.isSample else { return athlete.posts }
        let pulses = pulseSessions[athlete.handle] ?? []
        let total = athlete.totalWorkouts + pulses.count
        let want = min(max(limit, 1), total)
        if let cached = gridCache[athlete.handle], cached.count >= want || cached.count >= total {
            return cached
        }

        let sessions = CommunityLedger.sessions(
            handle: athlete.handle, primary: athlete.primaryType,
            // The city here is a real `CommunityRoutes` KEY ("Austin, TX", not "Austin" and not
            // the athlete's home town) — a miss means every GPS history post ships WITHOUT its map.
            city: athlete.routeCity,
            count: athlete.totalWorkouts, clock: seedClock, lead: athlete.ledgerLead,
            limit: max(0, want - pulses.count))
        var items = CommunityGenerator.gridPosts(handle: athlete.handle, name: athlete.name,
                                                 city: athlete.routeCity,
                                                 place: athlete.location ?? athlete.routeCity,
                                                 sessions: sessions, now: now)
        // The featured eight lead with a written post; it IS ledger entry 0, so it replaces the
        // tile that entry would otherwise have generated rather than sitting on top of it.
        if athlete.ledgerLead != nil, let curated = athlete.posts.first, !items.isEmpty {
            items[0] = curated
        }
        let posts = pulses.map(\.item) + items
        remember(athlete.handle)
        gridCache[athlete.handle] = posts
        return posts
    }

    /// Every lifetime number a community profile shows, folded out of that athlete's ledger — the
    /// single source the trio, the lifetime cells, the discipline split, the heatmap and the
    /// trophy case all read. Includes any pulse sessions, so a workout the wall just surfaced is
    /// counted by the profile it belongs to.
    @MainActor
    static func lifetime(for athlete: CommunityAthlete) -> CommunityLifetime {
        guard athlete.isSample else {
            var l = CommunityLifetime()
            l.sessions = athlete.totalWorkouts
            l.distanceM = athlete.totalDistanceM
            l.streakDays = athlete.dayStreak
            l.newestSession = nil
            return l
        }
        if let hit = lifetimeCache[athlete.handle] { return hit }
        var life = CommunityLedger.lifetime(
            handle: athlete.handle, primary: athlete.primaryType,
            city: athlete.routeCity,
            count: athlete.totalWorkouts, clock: seedClock, lead: athlete.ledgerLead)
        for pulse in (pulseSessions[athlete.handle] ?? []).map(\.session) {
            life.sessions += 1
            life.distanceM += pulse.distanceM
            life.durationS += pulse.durationS
            life.typeCounts[pulse.type, default: 0] += 1
            life.activeDays.insert(pulse.day)
            life.dayMinutes[pulse.day, default: 0] += pulse.durationS / 60
            life.longestDistanceM = max(life.longestDistanceM, pulse.distanceM)
            life.longestDurationS = max(life.longestDurationS, pulse.durationS)
            life.newestSession = pulse
        }
        if !(pulseSessions[athlete.handle] ?? []).isEmpty {
            life.streakDays = StreakCalculator.currentStreak(countingDays: life.activeDays,
                                                            today: seedClock.today)
        }
        remember(athlete.handle)
        lifetimeCache[athlete.handle] = life
        return life
    }

    /// Records a pulse-minted session against its athlete and drops their cached derivations so
    /// the next read counts it.
    @MainActor
    static func recordPulse(_ session: CommunitySession, item: FeedItem, for handle: String) {
        pulseSessions[handle, default: []].insert((session, item), at: 0)
        gridCache[handle] = nil
        lifetimeCache[handle] = nil
    }

    @MainActor
    private static func remember(_ handle: String) {
        cacheOrder.removeAll { $0 == handle }
        cacheOrder.append(handle)
        while cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            gridCache[evicted] = nil
            lifetimeCache[evicted] = nil
        }
    }

    private static func pid(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!
    }
}

private struct CommunityAuthor {
    let handle: String, name: String, location: String?
    init(_ handle: String, _ name: String, _ location: String?) {
        self.handle = handle; self.name = name; self.location = location
    }
}


#if DEBUG
import os

/// TEMPORARY probe for the 2026-08-29 load pass (`--community-perf`). Reports what the directory
/// build cost and how deep in time the wall's first screenfuls actually reach — the two numbers
/// the pass is tuning. Remove with the rest of `CommunityPerf`.
enum CommunityBuildProbe {
    private static let log = Logger(subsystem: "com.momentum.perf", category: "community")

    static func dump(_ athletes: [CommunityAthlete], since t0: CFAbsoluteTime, now: Date) {
        guard ProcessInfo.processInfo.arguments.contains("--community-perf") else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let probe0 = CFAbsoluteTimeGetCurrent()
        defer {
            log.notice("PROBECOST \(String(format: "%.1fms", (CFAbsoluteTimeGetCurrent() - probe0) * 1000), privacy: .public)")
        }
        let dates = athletes.flatMap(\.posts).map(\.date).sorted(by: >)
        func ageH(_ i: Int) -> Double {
            guard dates.indices.contains(i) else { return -1 }
            return now.timeIntervalSince(dates[i]) / 3600
        }
        let line = String(format:
            "DIRBUILD %.1fms (fold %.1f post %.1f) athletes=%d posts=%d ageH #1=%.3f #6=%.3f #12=%.3f #30=%.3f #60=%.3f #120=%.2f #300=%.2f #600=%.2f #1200=%.2f last=%.2f",
            ms, CommunityGenerator.probeFoldMs, CommunityGenerator.probePostMs,
            athletes.count, dates.count,
            ageH(0), ageH(5), ageH(11), ageH(29), ageH(59), ageH(119),
            ageH(299), ageH(599), ageH(1199), ageH(dates.count - 1))
        log.notice("\(line, privacy: .public)")
        // How many posts land inside each "how long ago" label the wall prints, so the smear is
        // visible as a count rather than a feeling.
        let buckets: [(String, Double)] = [("<5m", 5.0 / 60), ("<15m", 0.25), ("<1h", 1), ("<3h", 3),
                                           ("<6h", 6), ("<12h", 12), ("<24h", 24)]
        let counts = buckets.map { label, h in "\(label)=\(dates.filter { now.timeIntervalSince($0) < h * 3600 }.count)" }
        log.notice("DIRAGES \(counts.joined(separator: " "), privacy: .public)")
        writeIdentities(athletes)
    }

    /// The identity contract, dumped whole so a before/after diff can prove a generator change
    /// reshuffled nobody. `(handle, name, city, discipline, totalWorkouts)` is the tuple the rng
    /// draw order decides — see the note on `CommunityGenerator.athlete(index:)`. The city column
    /// is the METRO, which is what the rng draws; the home town beside it is picked off a separate
    /// hash and is not part of the contract.
    private static func writeIdentities(_ athletes: [CommunityAthlete]) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let body = athletes.map {
            "\($0.handle)\t\($0.name)\t\($0.metro ?? $0.location ?? "-")\t\($0.primarySport?.rawValue ?? "-")\t\($0.totalWorkouts)\t\($0.location ?? "-")"
        }.joined(separator: "\n")
        try? body.write(to: dir.appendingPathComponent("identity.tsv"), atomically: true, encoding: .utf8)
        log.notice("DIRIDENT wrote \(athletes.count, privacy: .public) rows")
    }
}
#endif
