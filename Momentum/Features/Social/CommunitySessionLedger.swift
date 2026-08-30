import Foundation

/// One session in a seeded community athlete's training life.
///
/// Deliberately light — no route points, no caption, no photo, no muscle map. An athlete with 900
/// sessions costs ~50 KB of these, so a whole career can be the source of truth for their profile
/// numbers without ever building 900 feed cards. `CommunityGenerator` materializes a rich
/// `FeedItem` from one of these only when a tile is about to be drawn.
struct CommunitySession: Sendable, Hashable {
    /// `StreakCalculator.localDay` — the calendar day this happened on.
    let day: Int
    /// The session start, with a plausible time of day for this athlete.
    let date: Date
    let type: WorkoutType
    /// Metres covered. Zero for every sport that doesn't cover ground (`!type.isGPS`), which is
    /// what keeps a lifter's lifetime distance honestly at zero.
    let distanceM: Double
    let durationS: Double
    /// Index into the city's bundled loop pool when this session traced a real street loop; nil
    /// means it shows no map (a track/tempo night, a trail run, a gym or pool session).
    let routePool: Int?
    /// A structured session — track reps, tempo, hills. Titled as a workout, and never mapped
    /// (a "Track night" over a downtown street loop is the loudest fake tell there is).
    let structured: Bool
}

/// Everything a community athlete's profile claims about their body of work, folded out of their
/// ledger. Every number here is a sum, a count or a max over the SAME sessions the grid shows, so
/// the trio, the lifetime cells, the discipline split, the heatmap and the trophy case can't
/// contradict each other or the tiles underneath them.
struct CommunityLifetime: Sendable {
    var sessions = 0
    var distanceM = 0.0
    var durationS = 0.0
    var streakDays = 0
    var typeCounts: [WorkoutType: Int] = [:]
    /// Every day they trained (whole career when `detail`, the last ~400 days otherwise).
    var activeDays: Set<Int> = []
    /// Training minutes per day, last 16 weeks — the heatmap's stepped intensity. Empty unless
    /// the fold was asked for `detail`.
    var dayMinutes: [Int: Double] = [:]
    var longestDistanceM = 0.0
    /// Longest single session on foot — the number the long-run award ladder reads, so a medal for
    /// a marathon can only exist if a marathon is actually somewhere in the grid.
    var longestFootM = 0.0
    var longestDurationS = 0.0
    /// Ledger entry 0 — the newest thing they did.
    var newestSession: CommunitySession?
    /// The newest session in their OWN sport, and where it sits in the ledger. This is the one
    /// that becomes their feed post: a runner's card on the wall should be a run even on a week
    /// they last did a gym session, and the wall's run-dominance rests on it. It is a real ledger
    /// entry, so the post it makes is the very tile the grid draws at that index — never an extra.
    var leadSession: CommunitySession?
    var leadIndex = 0
    var oldest: Date?
    var newest: Date? { newestSession?.date }
}

/// The lazy half of a seeded athlete's body of work — a **cache**, not a second aggregator: it
/// folds through `CommunityLedger.lifetime`, the one source of truth, and only decides *when*.
///
/// `CommunityAthlete.dayStreak` and `.totalDistanceM` were filled for every athlete at launch,
/// which meant walking ~770,000 sessions before the wall could draw one tile. Nothing on the wall
/// reads either number, so they fold on the first read instead. Locked rather than actor-isolated
/// because the wall's assembly runs on a detached task while profiles read on the main actor.
///
/// Folds against `CommunityDirectory.seedClock` — the community's ONE clock, the same instant every
/// other derivation uses, so a streak read here and a grid built there can never be measured from
/// two different "todays". A seeded athlete built against some other clock (only tests do this)
/// must read its numbers through `CommunityLedger.lifetime` directly rather than through here.
enum CommunityLedgerMemo {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: CommunityLifetime] = [:]
        private var order: [String] = []
        /// A browse touches a handful of athletes; this is generous for that and bounded for a
        /// script that walks the whole directory.
        private let limit = 96

        func lifetime(_ athlete: CommunityAthlete) -> CommunityLifetime {
            lock.lock()
            if let hit = cache[athlete.handle] { lock.unlock(); return hit }
            lock.unlock()
            // Folded OUTSIDE the lock: two threads asking for the same athlete at once do the work
            // twice rather than one of them blocking on a whole-career walk.
            let life = CommunityLedger.lifetime(
                handle: athlete.handle, primary: athlete.primaryType,
                city: athlete.routeCity,
                count: athlete.totalWorkouts, clock: CommunityDirectory.seedClock,
                lead: athlete.ledgerLead, detail: false)
            lock.lock()
            defer { lock.unlock() }
            if cache[athlete.handle] == nil {
                cache[athlete.handle] = life
                order.append(athlete.handle)
                while order.count > limit { cache[order.removeFirst()] = nil }
            }
            return life
        }
    }

    private static let store = Store()

    static func lifetime(of athlete: CommunityAthlete) -> CommunityLifetime { store.lifetime(athlete) }
}

/// The **one** deterministic source of truth for a seeded community athlete's training history.
///
/// The bug this exists to make impossible (owner report 2026-08-28: "if they have thirty miles
/// tracked from their grid, that should match their miles on their profile"): the grid used to be
/// ~15 generated history posts while `totalWorkouts` / `totalDistanceM` / `dayStreak` were three
/// *independent* draws. A profile could claim 1,181 miles over a grid whose visible sessions summed
/// to thirty, and a 23-day streak over a grid whose newest tile was four days old. Nothing tied
/// them together, so no amount of tuning constants could.
///
/// Now every one of those numbers is a fold over this ledger and every tile is one of its entries,
/// so they reconcile **by construction**. The walk is also shaped like a training life rather than
/// a uniform generator: a weekly rhythm with rest days and a weekend long run, down weeks every
/// fourth week, a seasonal swing, the occasional injury or travel gap, doubles for high-volume
/// athletes, a sparser first few months, and sessions clustered in the athlete's own time of day.
/// A beginner with eight sessions gets a three-week-deep history, never a five-year heatmap.
enum CommunityLedger {

    /// The window every profile's consistency heatmap draws.
    static let heatmapWindowDays = 16 * 7

    /// Athletes without a location still need real street loops; this must stay a real
    /// `CommunityRoutes` key ("Austin, TX", never "Austin").
    static let fallbackCity = "Austin, TX"

    /// The calendar facts a walk needs, resolved once. `Calendar` lookups are the single most
    /// expensive thing in the fold (the directory folds ~2,900 careers at launch), and every one
    /// of them can be derived by integer arithmetic from these four.
    struct Clock: Sendable {
        let asOf: Date
        /// `StreakCalculator.localDay(asOf)`.
        let today: Int
        let dayStart: Date
        /// Weekday of `today`, 0 = Sunday.
        let dow: Int
        let secondsIntoDay: Double

        init(_ asOf: Date, calendar: Calendar = .current) {
            self.asOf = asOf
            today = StreakCalculator.localDay(asOf, calendar: calendar)
            let start = calendar.startOfDay(for: asOf)
            dayStart = start
            dow = calendar.component(.weekday, from: asOf) - 1
            secondsIntoDay = asOf.timeIntervalSince(start)
        }
    }

    // MARK: The walk

    /// Streams an athlete's whole training life, **newest first**, without allocating an array.
    ///
    /// Emits exactly `count` sessions — that is the invariant the session-count trio rests on —
    /// unless `body` asks it to stop. `lead` pins the newest entry (the hand-curated featured
    /// athletes each have one real post that must stay their most recent session) and the walk
    /// continues from the day before it.
    ///
    /// **`body` returns "keep going".** Every consumer except the whole-career fold wants a
    /// PREFIX: the wall needs one session per athlete, the profile grid needs thirty. Walking a
    /// 900-session career to read its first entry was the single most expensive thing the app did
    /// at launch (611 ms across ~2,900 athletes, measured 2026-08-29). Stopping early changes no
    /// value the walk already emitted — the rng is consumed in emission order — so a prefix is
    /// bit-identical to the same prefix of the full walk.
    static func walk(handle: String, primary: WorkoutType, city: String, count: Int,
                     clock: Clock, lead: CommunitySession? = nil,
                     _ body: (CommunitySession) -> Bool) {
        guard count > 0 else { return }
        var rng = SeededRNG(seed("ledger:\(handle)"))

        // --- The athlete's career shape, drawn once. -------------------------------------------
        // Volume tracks the body of work: someone with 800 sessions behind them trains most days,
        // someone with 12 trains a couple of times a week. This is what keeps a beginner's history
        // a few weeks deep instead of spreading eight sessions over five years.
        let tilt = min(1.0, Double(count) / 520.0)
        let weekly = max(1.8, 2.2 + 3.4 * tilt + rng.double(-0.6, 0.9))
        let baseP = max(0.20, min(0.90, weekly / 7))
        let restDow = rng.int(0...6)                       // their usual full day off
        let longDow = rng.int(0...1) == 0 ? 6 : 0          // Saturday or Sunday long session
        let seasonPhase = rng.int(0...11)                  // where their year peaks
        let chronotype = rng.int(0...9)                    // early (0) → late (9); see `peakHour`
        let volumeFactor = rng.double(0.78, 1.28)          // their sessions run short or long
        let doubles = weekly > 5.2
        // The long day's distance, scaled by how deep the athlete is: a beginner's "long one" is
        // 10 km, a veteran marathoner's is thirty. It is drawn rather than taken from a loop
        // because only three street loops ship per city and none of them is a long run — before
        // this, a sub-3 marathoner's 312 sessions summed to 885 miles because every single run
        // she ever did was a 2-to-6-mile neighbourhood loop.
        let longScale = volumeFactor * rng.double(0.85, 1.15)
        // Paces are per athlete, jittered per session, so their splits read like one person's.
        let runPace = rng.double(280, 430)
        let trailPace = rng.double(345, 480)
        let ridePace = rng.double(116, 180)
        let walkPace = rng.double(600, 870)

        // The bundled street loops for this athlete's city, lengths only. One dictionary lookup
        // per pool per athlete instead of one per session.
        // Their own hour of the day, and the opposite end of it for the second session of a
        // double. Derived from a hash rather than a draw so the walk's rng stream is untouched.
        let peak = peakHour(chronotype: chronotype, handle: handle)
        let peakAlt = peakHour(chronotype: 9 - chronotype, handle: handle)

        let runKms = CommunityRoutes.loopKms(city: city, discipline: .run)
        let rideKms = CommunityRoutes.loopKms(city: city, discipline: .ride)
        // The city's longest FEW loops, not just the single longest. Taking one fixed loop meant
        // every long run in a city drew the identical trace, and the long-day away-chance was
        // pushed to 60 to hide that. The bundled pool is 11 run loops per city now (was 3, with
        // 546 distinct lengths overall), so that trade is no longer necessary.
        let longRunPool: [Int] = Array(runKms.indices.sorted { runKms[$0] > runKms[$1] }.prefix(4))
        let cross: [WorkoutType] = primary.isGPS ? [.strength, .walk, .hiit] : [.run, .walk, .strength]

        // --- The day-by-day walk. ---------------------------------------------------------------
        var emitted = 0
        var day = clock.today
        var lastPool = -1          // the previous mapped session's loop, so a shape never repeats
        var breakLeft = 0          // an injury or a trip: a run of days with nothing in them
        var walked = 0
        // Force-fill guard. Expected emission is ≥0.16/day, so this never fires in practice; it
        // exists so `count` is reached even if the shape parameters are ever retuned badly.
        let forceAfter = count * 8 + 300
        let hardStop = count * 12 + 600

        if let lead {
            guard body(lead) else { return }
            emitted = 1
            day = lead.day - 1
        }

        while emitted < count && walked < hardStop {
            let dow = weekday(day, clock: clock)
            let isLongDay = dow == longDow && primary.isGPS

            var p = baseP
            if dow == restDow && !isLongDay { p *= 0.18 }
            if dow == 0 || dow == 6 { p *= 1.12 }
            // Down week every fourth week — real plans back off, and a heatmap without troughs
            // reads like a random scatter.
            if ((clock.today - day) / 7) % 4 == 3 { p *= 0.62 }
            p *= Self.season[(day / 30 + seasonPhase) % 12]
            // Their first months are thinner than their current form.
            let progress = Double(emitted) / Double(count)
            if progress > 0.82 { p *= 1 - 0.55 * (progress - 0.82) / 0.18 }

            if breakLeft > 0 {
                breakLeft -= 1
                p = 0
            } else if rng.int(0...399) == 0 {
                breakLeft = rng.int(5...18)     // ~1-2 breaks a year
                p = 0
            }

            let forced = walked > forceAfter
            if forced || rng.double(0, 1) < p {
                if let s = session(day: day, isLong: isLongDay, clock: clock, primary: primary,
                                   cross: cross, runKms: runKms, rideKms: rideKms,
                                   longRunPool: longRunPool, lastPool: &lastPool,
                                   volumeFactor: volumeFactor, tilt: tilt, longScale: longScale,
                                   chronotype: chronotype, peakHour: peak,
                                   runPace: runPace, trailPace: trailPace,
                                   ridePace: ridePace, walkPace: walkPace, rng: &rng) {
                    guard body(s) else { return }
                    emitted += 1
                    // A second session the same day — the easy shakeout or the evening lift that
                    // high-volume athletes actually log.
                    if doubles, emitted < count, rng.int(0...9) == 0,
                       let extra = session(day: day, isLong: false, clock: clock, primary: primary,
                                           cross: cross, runKms: runKms, rideKms: rideKms,
                                           longRunPool: longRunPool, lastPool: &lastPool,
                                           volumeFactor: volumeFactor * 0.7, tilt: tilt,
                                           longScale: longScale, chronotype: 9 - chronotype,
                                           peakHour: peakAlt,
                                           runPace: runPace, trailPace: trailPace,
                                           ridePace: ridePace, walkPace: walkPace, rng: &rng) {
                        guard body(extra) else { return }
                        emitted += 1
                    }
                }
            }
            walked += 1
            day -= 1
        }
    }

    /// One session on `day`. Returns nil only for today when the drawn start time hasn't arrived
    /// yet — nobody has a session in the future, and "hasn't trained yet today" is exactly what a
    /// community should look like at 6am.
    private static func session(day: Int, isLong: Bool, clock: Clock, primary: WorkoutType,
                                cross: [WorkoutType], runKms: [Double], rideKms: [Double],
                                longRunPool: [Int], lastPool: inout Int,
                                volumeFactor: Double, tilt: Double, longScale: Double,
                                chronotype: Int, peakHour peak: Double,
                                runPace: Double, trailPace: Double, ridePace: Double,
                                walkPace: Double, rng: inout SeededRNG) -> CommunitySession? {
        // Their own sport leads (the same ~62% the grid has always used); the long day is always
        // their sport, because that is what a long day IS.
        var type: WorkoutType = rng.int(0...99) < 62 ? primary : rng.pick(cross)
        if isLong { type = primary }

        // Time of day: people train at their hour, not at random. Long days start early.
        // ONE draw either way — the shape of the window changed, the rng consumption did not.
        // ±1.45h, not ±1.15: nobody starts at the same minute every day, and the width of this
        // window is half of what decides how densely the community's posts arrive at any instant.
        let hour: Double = isLong
            ? rng.double(max(5.4, peak - 2.1), max(7.9, peak + 0.5))
            : rng.double(peak - 1.45, peak + 1.45)
        let seconds = hour * 3600
        if day == clock.today && seconds > clock.secondsIntoDay { return nil }
        let date = clock.dayStart.addingTimeInterval(Double(day - clock.today) * 86_400 + seconds)

        let structured = type == .run && !isLong && rng.int(0...99) < 8
        // Sessions that leave the neighbourhood: they take a drawn distance and no map, the way a
        // real watch post from somewhere the bundle has no geometry for does. Long days mostly go
        // somewhere else, and so does a decent share of rides — only ONE ride loop ships per city
        // and they are all ~14 miles, so mapping every ride made every cyclist on the wall post
        // the same number. This is also where the distances BETWEEN the bundled loop lengths come
        // from: without it a city's runs can only ever be one of three numbers.
        //
        // **`.run` came down from 10 to 5 and the long day from 25 to 14 (2026-08-29)**, because
        // the premise of the higher numbers expired: they were sized when a city shipped THREE run
        // loops, all short, so a runner had to leave the bundle to have an honest range of
        // distances at all ("without it a city's runs can only ever be one of three numbers").
        // The bundle now ships 8 to 11 run loops per city spanning 2.0 to 21.1 km, so the range is
        // there without the escape hatch — and every away run is a mapless tile drawing the
        // identical `figure.run` glyph as every other, which is the one picture the wall has too
        // many of (`noSportClumpsBeyondWhatSpacingCanAbsorb` / `neverTwoOfTheSamePictureSideBySide`
        // are what catch it, and the fix for those belongs here in the generator, never in
        // `spaced`).
        let everydayAwayChance: Int = switch type {
        case .ride, .mountainBikeRide, .gravelRide: 40
        case .run: 5
        case .walk, .hike: 12
        default: 0
        }
        // A LATENT WEEKEND BUG lived here (found 2026-08-29, a Saturday). The long day is always
        // Saturday or Sunday, `isLong` forces `type = primary`, and that is exactly the session
        // `leadSession` picks as the athlete's wall card — so on those two days roughly half the
        // GPS community's wall post was their long run, at SIX times the mapless rate. The wall
        // showed barely half its usual maps every weekend, which is when a running app is most
        // looked at, and it read as a wall of bare glyphs. `routedPostsDominateTheWall` predicts
        // 73.8% on a weekday (74.8% measured) against ~41% on a Saturday (43% measured).
        // 60 existed only to keep long runs off one identical bundled loop; `longRunPool` now
        // solves that directly, so this can come down to something honest.
        let awayChance = isLong ? 14 : everydayAwayChance
        let away = type.isGPS && !structured && rng.int(0...99) < awayChance
        // Trail runs never map (no bundled trail geometry exists) and structured nights never map.
        let pool = type == .ride ? rideKms : runKms
        let mappable = type.isGPS && type != .trailRun && !structured && !away && !pool.isEmpty

        var distanceM = 0.0
        var routePool: Int?
        if away {
            distanceM = (isLong ? longDistanceKm(type, tilt: tilt, scale: longScale, rng: &rng)
                                : drawnDistanceKm(type, volumeFactor: volumeFactor, rng: &rng)) * 1000
        } else if mappable {
            // The long day takes the city's biggest loop — that is what makes the weekly rhythm
            // visible in the distances. Everything else draws freely from the pool EXCEPT the loop
            // the previous mapped session used.
            //
            // Two failed shapes are worth remembering. Skipping the longest loop in the rotation
            // (to keep a long run off an identical neighbouring tile) quietly meant regular runs
            // only ever used a city's two SHORTEST loops, and three quarters of the wall read
            // "2.1 mi". And a strict `slot % count` rotation reads as a repeating cycle down a
            // long grid — 5.5, 2.2, 3.7, 5.5, 2.2, 3.7 — which is its own generator tell. Drawing
            // from "anything but the last one" gives no repeat and no period.
            var index: Int
            let n = pool.count
            if isLong && type == .run, !longRunPool.isEmpty {
                // Rotated by (day, chronotype), NOT drawn: consuming an rng value here would
                // shift every subsequent session in this athlete's history. `day` varies week to
                // week and `chronotype` varies athlete to athlete, so two neighbours' Saturday
                // long runs are different shapes rather than one traced twice.
                let n = longRunPool.count
                index = longRunPool[((day &+ chronotype) % n + n) % n]
            } else if n == 1 {
                index = 0
            } else if lastPool >= 0 && lastPool < n {
                index = rng.int(0...(n - 2))
                if index >= lastPool { index += 1 }
            } else {
                index = rng.int(0...(n - 1))
            }
            lastPool = index
            routePool = index
            distanceM = pool[index] * 1000
        } else if type.isGPS {
            let band = band(for: type)
            let base = (band.lowerBound + rng.double(0, band.upperBound - band.lowerBound)) * volumeFactor
            distanceM = base * (isLong ? rng.double(1.45, 2.15) : rng.double(0.78, 1.2)) * 1000
        }

        let durationS: Double
        if type.isGPS {
            let pace: Double = switch type {
            case .trailRun: trailPace
            case .ride, .mountainBikeRide, .gravelRide: ridePace
            case .walk, .hike: walkPace
            default: structured ? runPace * 0.88 : runPace
            }
            durationS = (distanceM / 1000) * pace * rng.double(0.94, 1.07)
        } else if type.isStrengthStyle {
            durationS = Double(rng.int(35 * 60...80 * 60))
        } else {
            durationS = Double(rng.int(20 * 60...70 * 60))
        }

        return CommunitySession(day: day, date: date, type: type, distanceM: distanceM,
                                durationS: durationS, routePool: routePool, structured: structured)
    }

    // MARK: Folds

    /// Every number a community profile displays, folded out of one walk.
    ///
    /// `detail: false` skips the whole-career day set and the heatmap minutes — the launch-time
    /// pass that fills an athlete's stored totals needs neither, and skipping them keeps generating
    /// ~2,900 careers off the cold-start budget.
    static func lifetime(handle: String, primary: WorkoutType, city: String, count: Int,
                         clock: Clock, lead: CommunitySession? = nil,
                         detail: Bool = true) -> CommunityLifetime {
        var out = CommunityLifetime()
        var days = Set<Int>()
        days.reserveCapacity(detail ? count : 64)
        var minutes: [Int: Double] = [:]
        let windowStart = clock.today - heatmapWindowDays + 1
        // Streaks can only ever be measured from recent days; the light fold keeps just those.
        let dayFloor = detail ? Int.min : clock.today - 400

        // A pinned lead IS the wall card — the featured eight's curated post is their newest
        // session by construction and never has to qualify.
        let pinned = lead != nil
        walk(handle: handle, primary: primary, city: city, count: count, clock: clock, lead: lead) { s in
            if out.leadSession == nil,
               (pinned && out.sessions == 0)
                   || isLead(s, primary: primary, handle: handle, index: out.sessions) {
                out.leadSession = s
                out.leadIndex = out.sessions
            }
            out.sessions += 1
            out.distanceM += s.distanceM
            out.durationS += s.durationS
            // The launch-time pass fills stored totals only; skipping the per-session dictionary
            // update there is most of what keeps folding ~2,900 careers off the cold-start budget.
            if detail { out.typeCounts[s.type, default: 0] += 1 }
            out.longestDistanceM = max(out.longestDistanceM, s.distanceM)
            if s.type == .run || s.type == .trailRun {
                out.longestFootM = max(out.longestFootM, s.distanceM)
            }
            out.longestDurationS = max(out.longestDurationS, s.durationS)
            if s.day >= dayFloor { days.insert(s.day) }
            if detail && s.day >= windowStart { minutes[s.day, default: 0] += s.durationS / 60 }
            if out.newestSession == nil { out.newestSession = s }
            out.oldest = s.date
            return true
        }
        // A career with no session in their own sport is astronomically unlikely (0.38^n) but the
        // lead must always resolve to a real ledger entry.
        if out.leadSession == nil { out.leadSession = out.newestSession; out.leadIndex = 0 }

        out.activeDays = days
        out.dayMinutes = minutes
        // The app's own streak rule, applied to their real days — so a "23 day streak" can never
        // sit above a grid whose newest tile is four days old.
        out.streakDays = StreakCalculator.currentStreak(countingDays: days, today: clock.today)
        return out
    }

    /// The newest `limit` sessions, materialized. Paging the profile grid means never building
    /// more of a 900-session career than the athlete has actually scrolled to — and, since
    /// 2026-08-29, never *walking* more of it either: the guard used to run inside a walk that
    /// still went all the way to the end, so opening a veteran's profile paid their whole career
    /// to show thirty tiles.
    static func sessions(handle: String, primary: WorkoutType, city: String, count: Int,
                         clock: Clock, lead: CommunitySession? = nil,
                         limit: Int = .max) -> [CommunitySession] {
        guard limit > 0 else { return [] }
        var out: [CommunitySession] = []
        out.reserveCapacity(Swift.min(limit, count))
        walk(handle: handle, primary: primary, city: city, count: count, clock: clock, lead: lead) { s in
            out.append(s)
            return out.count < limit
        }
        return out
    }

    // MARK: The wall card

    /// The session an athlete's wall card shows, and where it sits in their ledger.
    ///
    /// **This is the whole reason the directory can be built cheaply.** The card is a prefix
    /// property — the newest ledger entry that satisfies `isLead` — so it needs a handful of
    /// walked days, not a whole career. The launch pass folded ~770,000 sessions to read ~2,900
    /// of them; this walks about six sessions each. It returns exactly what
    /// `lifetime(...).leadSession` / `.leadIndex` would, including the fallback: a career with no
    /// qualifying session leads with its newest entry.
    static func lead(handle: String, primary: WorkoutType, city: String, count: Int,
                     clock: Clock, lead pinned: CommunitySession? = nil)
    -> (session: CommunitySession, index: Int)? {
        var newest: CommunitySession?
        var hit: (session: CommunitySession, index: Int)?
        var index = 0
        // Same rule as the fold: a pinned lead IS the card, and never has to qualify.
        let isPinned = pinned != nil
        walk(handle: handle, primary: primary, city: city, count: count, clock: clock, lead: pinned) { s in
            if newest == nil { newest = s }
            if (isPinned && index == 0)
                || isLead(s, primary: primary, handle: handle, index: index) {
                hit = (s, index)
                return false
            }
            index += 1
            return true
        }
        return hit ?? newest.map { ($0, 0) }
    }

    /// Whether this ledger entry is the one their wall card shows: **a session in their own sport
    /// that they shared.**
    ///
    /// Two facts about the sport half. A runner's card should be a run even in a week they last
    /// did a gym session, and the wall's run-dominance rests on it.
    ///
    /// The sharing half is what makes the top of the wall readable (owner report 2026-08-29: the
    /// first screenful all read "3 to 5 minutes ago"). Every athlete's newest own-sport session
    /// used to be a post, so ~1,384 of 2,871 athletes posted inside a day and the arrivals piled up
    /// against the training-hour bands: 300 posts inside a single morning hour, and a first
    /// screenful spanning fifteen minutes at noon and five at dawn. Real people do not post every
    /// workout, and the app already draws this exact line for its own athlete — the profile grid
    /// is the training log, the wall is what was SHARED (`SocialPrivacy.isShared`). The community
    /// now works the same way: every session is still a tile on its author's grid, but only some
    /// of them are posts, so the wall thins out to a rate a person can read.
    ///
    /// Drawn from a hash, never from the walk's rng: a draw here would shift every later session
    /// in the athlete's history (and `athlete(index:)`'s identity contract sits upstream of that).
    static func isLead(_ s: CommunitySession, primary: WorkoutType,
                       handle: String, index: Int) -> Bool {
        guard s.type == primary else { return false }
        return Int(seedHash("share:\(handle):\(index)") % 1000) < shareRatePerMille(handle)
    }

    /// How much of their training this athlete puts on the wall, per mille. Power-curved and
    /// per-athlete: most people share a fraction of what they do, a few share nearly everything.
    /// The mean (~0.26) is the lever that sets how deep in time the wall's first screenful reaches.
    private static func shareRatePerMille(_ handle: String) -> Int {
        let u = Double(seedHash("shares:\(handle)") % 10_000) / 10_000
        return 45 + Int(640 * pow(u, 1.95))
    }

    // MARK: Shape helpers

    /// The long day's distance for a sport, scaled by how deep into their training life the
    /// athlete is. A first-timer's long run is 10 km; a veteran's is a marathon's worth.
    private static func longDistanceKm(_ type: WorkoutType, tilt: Double, scale: Double,
                                       rng: inout SeededRNG) -> Double {
        let (base, cap): (Double, Double) = switch type {
        case .run: (9 + 19 * tilt, 34)
        case .trailRun: (11 + 15 * tilt, 32)
        case .ride, .mountainBikeRide, .gravelRide: (38 + 55 * tilt, 128)
        case .walk, .hike: (5.5 + 5.5 * tilt, 20)
        default: (6 + 6 * tilt, 18)
        }
        return min(cap, max(2, base * scale * rng.double(0.86, 1.14)))
    }

    /// An everyday session that didn't trace a bundled loop, drawn around the athlete's own
    /// typical rather than a flat band — this is what puts distances BETWEEN the three loop
    /// lengths a city ships, so a wall of runs isn't three numbers repeated.
    private static func drawnDistanceKm(_ type: WorkoutType, volumeFactor: Double,
                                        rng: inout SeededRNG) -> Double {
        let band = band(for: type)
        let base = band.lowerBound + rng.double(0, band.upperBound - band.lowerBound)
        return max(1, base * volumeFactor * rng.double(0.8, 1.18))
    }

    /// Per-session distance bands by sport — the same everyday-athlete ranges the generator has
    /// always used, now applied only to the sessions that don't take a real street loop.
    private static func band(for type: WorkoutType) -> ClosedRange<Double> {
        switch type {
        case .run: 4...11
        case .trailRun: 7...17
        case .ride, .mountainBikeRide, .gravelRide: 18...45
        case .walk, .hike: 2.5...6.5
        default: 3...8
        }
    }

    /// The hour this athlete trains at, as a **continuous** value spread across the waking day.
    ///
    /// It used to be three buckets — 60% of the community started between 5.2 and 8.8, 20% between
    /// 11.2 and 14.2, 20% in the evening. Reverse-chronologically that is a cliff, not a feed: at
    /// 07:00 roughly three hundred of the wall's newest posts sat inside one hour, so the first
    /// screenful spanned five minutes and every tile read "3 min ago"; at 14:00 the same wall had a
    /// 300-post step five hours back where the morning block ended. Real communities have somebody
    /// starting in every hour. Monotone in `chronotype`, so `9 - chronotype` still means "the other
    /// end of their day" for the second session of a double, and front-biased because more people
    /// train early than late.
    /// **The exponent is the whole point and it has to stay near 1.** A curve steeper than that
    /// piles athletes into the early hours again: at 1.55 seven percent of the community peaked
    /// inside each dawn hour against under four percent per evening hour, and the 07:00 wall was
    /// back to a first screenful spanning five minutes (measured, `theWallsFirstScreenfulReaches` —
    /// it caught exactly this). 1.15 keeps a real morning lean — about 7% of athletes start in the
    /// 7am hour against 5.5% in the 6pm hour — without any hour being a cliff.
    private static func peakHour(chronotype: Int, handle: String) -> Double {
        let jitter = Double(seedHash("chrono:\(handle)") % 1_000) / 1_000
        let t = (Double(chronotype) + jitter) / 10
        return 5.6 + 14.8 * pow(t, 1.15)
    }

    /// A twelve-step seasonal swing (northern-hemisphere shaped: a spring/autumn racing rhythm,
    /// a quieter deep winter). Indexed by month-ish so no `sin` runs per walked day.
    private static let season: [Double] = [0.88, 0.92, 1.02, 1.10, 1.12, 1.06,
                                           0.98, 1.00, 1.10, 1.12, 1.00, 0.90]

    /// Weekday of `day` (0 = Sunday) by integer arithmetic off the clock's known weekday.
    private static func weekday(_ day: Int, clock: Clock) -> Int {
        let anchor = clock.today - clock.dow
        return ((day - anchor) % 7 + 7) % 7
    }

    /// FNV-1a over the handle — the ledger's own seed space, independent of the sequential draws
    /// that decide an athlete's name, city and sport (spending a draw there would reshuffle every
    /// identity in the directory).
    private static func seed(_ key: String) -> Int {
        Int(bitPattern: UInt(truncatingIfNeeded: seedHash(key)))
    }

    static func seedHash(_ key: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
}
