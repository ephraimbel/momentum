import Foundation

/// The deterministic award detector (brand rule: every number rules-based and unit-testable).
/// Pure — takes a value-typed `Snapshot` of history and returns which awards are earned, **when**,
/// and **which workout earned them**, by replaying history chronologically and finding the first
/// crossing of each threshold. Re-running over the same history always yields the same result, so
/// the persistence layer (`AwardsBook`) can sync idempotently, exactly like `RecordsBook`.
enum AwardsEngine {

    // MARK: Inputs

    /// One workout, reduced to the facts awards read. SI units throughout. The later fields are
    /// `var` + default so older call sites (and test fixtures) stay valid as facts are added.
    struct Activity: Sendable {
        let id: UUID
        let date: Date
        let type: WorkoutType
        let distanceM: Double
        let elevationGainM: Double
        let durationS: Double
        let volumeKg: Double
        /// Local hour of day the workout started (0–23) — Dawn Patrol / Night Shift.
        let startHour: Int
        /// Completed working sets (strength) — the set-count ladder.
        var workingSets: Int = 0
        /// Muscle buckets this session trained — Full Coverage.
        var muscleBuckets: Set<MuscleBucket> = []
        /// Starting coordinate (GPS workouts) — Wanderer's distinct-places math. Optional and
        /// filled from a one-time memo, never by faulting every sample on every sync.
        var startLat: Double? = nil
        var startLon: Double? = nil

        /// `accumulate` walks Double key paths — the set ladder reuses it through this view.
        var workingSetsD: Double { Double(workingSets) }
    }

    /// The six coverage buckets "Full Coverage" asks for — coarse on purpose (nobody should lose
    /// the award to an untouched forearm isolation).
    enum MuscleBucket: String, CaseIterable, Sendable {
        case chest, back, shoulders, arms, legs, core

        static func buckets(for group: MuscleGroup) -> [MuscleBucket] {
            switch group {
            case .chest: [.chest]
            case .back: [.back]
            case .shoulders: [.shoulders]
            case .biceps, .triceps, .forearms: [.arms]
            case .quads, .hamstrings, .glutes, .calves: [.legs]
            case .core: [.core]
            case .fullBody: MuscleBucket.allCases
            }
        }
    }

    /// One ratified personal-record row (the record book persists every improvement, so these
    /// form a true progression — the first row under a threshold is when the barrier fell).
    struct RecordFact: Sendable {
        let type: PRType
        let value: Double
        let achievedAt: Date
        let workoutID: UUID?
    }

    /// One planned session, reduced to what Training awards read.
    struct PlannedFact: Sendable {
        let date: Date
        let status: SessionStatus
        let isRace: Bool
        let workoutID: UUID?
        /// Completed races only: the distance and moving time of the finishing workout — Race PR
        /// compares later races against earlier ones at the same distance class.
        var raceDistanceM: Double? = nil
        var raceDurationS: Double? = nil
    }

    struct Snapshot: Sendable {
        var activities: [Activity] = []
        var records: [RecordFact] = []
        var planned: [PlannedFact] = []
        /// Streak-counting day keys (qualifying-workout days ∪ planned rest days) — the same set
        /// the profile flame walks, so an award can never disagree with the streak it celebrates.
        var streakDays: Set<Int> = []
        var now: Date = Date()
    }

    struct Earned: Sendable, Equatable {
        let awardID: String
        let earnedAt: Date
        let workoutID: UUID?
    }

    /// A locked award's standing: how far along, in what unit — the view formats for display.
    struct Progress: Sendable, Equatable {
        enum Unit: Sendable { case meters, seconds, days, count, kilograms }
        let fraction: Double     // 0…1, clamped
        let current: Double
        let target: Double
        let unit: Unit
    }

    // MARK: Thresholds (pinned to the catalog by AwardsEngineTests)

    static let lifetimeDistanceM: [(id: String, m: Double)] = [
        ("distance.50", 50_000), ("distance.100", 100_000), ("distance.250", 250_000),
        ("distance.500", 500_000), ("distance.1000", 1_000_000), ("distance.2500", 2_500_000),
        ("distance.5000", 5_000_000),
    ]
    /// Single-run distances get a 0.5% underage tolerance — GPS habitually reads a hair short of
    /// the certified course, and a marathoner who crossed the line has run the marathon.
    static let singleRunM: [(id: String, m: Double)] = [
        ("longrun.5k", 5_000), ("longrun.10k", 10_000), ("longrun.half", 21_097.5),
        ("longrun.marathon", 42_195), ("longrun.ultra", 50_000),
    ]
    static let gpsTolerance = 0.995
    static let lifetimeClimbM: [(id: String, m: Double)] = [
        ("climb.1000", 1_000), ("climb.5000", 5_000), ("climb.everest", 8_849),
        ("climb.25000", 25_000), ("climb.50000", 50_000), ("climb.100000", 100_000),
    ]
    static let benchmarkS: [(id: String, type: PRType, s: Double)] = [
        ("speed.5k.sub30", .fastest5k, 1_800), ("speed.5k.sub25", .fastest5k, 1_500),
        ("speed.5k.sub20", .fastest5k, 1_200),
        ("speed.10k.sub60", .fastest10k, 3_600), ("speed.10k.sub50", .fastest10k, 3_000),
        ("speed.10k.sub45", .fastest10k, 2_700),
        ("speed.half.sub2", .fastestHalf, 7_200), ("speed.half.sub145", .fastestHalf, 6_300),
        ("speed.half.sub130", .fastestHalf, 5_400),
        ("speed.mara.sub4", .fastestMarathon, 14_400), ("speed.mara.sub330", .fastestMarathon, 12_600),
        ("speed.mara.sub3", .fastestMarathon, 10_800),
    ]
    static let streakDaysThresholds: [(id: String, days: Int)] = [
        ("streak.7", 7), ("streak.14", 14), ("streak.30", 30),
        ("streak.60", 60), ("streak.100", 100), ("streak.365", 365),
    ]
    static let timeOfDayCount = 5
    static let dawnHourEnd = 6      // started before 06:00
    static let nightHourStart = 21  // started at/after 21:00
    static let perfectWeeks: [(id: String, weeks: Int)] = [
        ("training.perfectweek", 1), ("training.perfectweek4", 4), ("training.perfectweek12", 12),
    ]
    /// A week needs a real training load before "perfect" means anything.
    static let perfectWeekMinSessions = 3
    static let comebackGapDays = 14
    static let strengthSessions: [(id: String, count: Int)] = [
        ("strength.first", 1), ("strength.10", 10), ("strength.50", 50), ("strength.100", 100),
    ]
    static let lifetimeVolumeKg: [(id: String, kg: Double)] = [
        ("volume.100t", 100_000), ("volume.500t", 500_000), ("volume.million", 1_000_000),
    ]
    /// A "first run" that's a 200 m GPS blip isn't a first run.
    static let firstRunFloorM = 1_000.0
    static let sessionCounts: [(id: String, count: Int)] = [
        ("sessions.10", 10), ("sessions.50", 50), ("sessions.100", 100),
        ("sessions.250", 250), ("sessions.500", 500), ("sessions.1000", 1_000),
    ]
    static let weeklyRunM: [(id: String, m: Double)] = [
        ("week.25", 25_000), ("week.40", 40_000), ("week.60", 60_000),
        ("week.80", 80_000), ("week.100", 100_000),
    ]
    static let rideLifetimeM: [(id: String, m: Double)] = [
        ("ride.100", 100_000), ("ride.500", 500_000),
        ("ride.1000", 1_000_000), ("ride.5000", 5_000_000),
    ]
    static let centuryRideM = 100_000.0
    static let sessionDurationS: [(id: String, s: Double)] = [
        ("endurance.1h", 3_600), ("endurance.2h", 7_200),
        ("endurance.3h", 10_800), ("endurance.4h", 14_400),
    ]
    static let singleClimbM: [(id: String, m: Double)] = [
        ("climb.single500", 500), ("climb.single1000", 1_000),
    ]
    static let raceCounts: [(id: String, count: Int)] = [
        ("training.race", 1), ("training.race3", 3), ("training.race10", 10),
    ]
    static let setCounts: [(id: String, count: Int)] = [
        ("strength.sets1000", 1_000), ("strength.sets10000", 10_000),
    ]
    static let wandererPlaces = 5
    static let wandererSeparationM = 25_000.0

    private static func isRun(_ a: Activity) -> Bool { a.type == .run || a.type == .trailRun }
    private static func isFoot(_ a: Activity) -> Bool {
        a.type == .run || a.type == .trailRun || a.type == .hike || a.type == .walk
    }
    /// Distance-ladder rides — e-bikes excluded (motor-assisted km aren't the same currency).
    private static func isRide(_ a: Activity) -> Bool {
        a.type == .ride || a.type == .mountainBikeRide || a.type == .gravelRide
    }
    private static func qualifies(_ a: Activity) -> Bool {
        StreakCalculator.workoutQualifies(type: a.type, distanceM: a.distanceM, activeSeconds: a.durationS)
    }

    // MARK: Evaluate

    static func evaluate(_ s: Snapshot, calendar: Calendar = .current) -> [Earned] {
        let acts = s.activities.sorted { $0.date < $1.date }
        var out: [Earned] = []

        // Lifetime running distance — first activity that carries the total across each line.
        out += accumulate(acts.filter(isRun), value: \.distanceM, thresholds: lifetimeDistanceM)

        // Single-run firsts.
        if let first = acts.first(where: { isRun($0) && $0.distanceM >= firstRunFloorM }) {
            out.append(Earned(awardID: "longrun.first", earnedAt: first.date, workoutID: first.id))
        }
        for (id, meters) in singleRunM {
            if let hit = acts.first(where: { isRun($0) && $0.distanceM >= meters * gpsTolerance }) {
                out.append(Earned(awardID: id, earnedAt: hit.date, workoutID: hit.id))
            }
        }

        // Lifetime climb, on foot.
        out += accumulate(acts.filter(isFoot), value: \.elevationGainM, thresholds: lifetimeClimbM)

        // Benchmark times — the first record row under each bar.
        let records = s.records.sorted { $0.achievedAt < $1.achievedAt }
        for (id, type, seconds) in benchmarkS {
            if let fact = records.first(where: { $0.type == type && $0.value > 0 && $0.value <= seconds }) {
                out.append(Earned(awardID: id, earnedAt: fact.achievedAt, workoutID: fact.workoutID))
            }
        }

        // Streaks — walk the counting days with the same 2-day grace as StreakCalculator and
        // record the day each run length is first reached. Ordinal keys are gap-free day counts
        // (see StreakCalculator.localDay), so `today + (day − todayOrdinal)` recovers the date.
        out += streakEarnings(s, calendar: calendar)

        // Time-of-day specials — the fifth one seals it.
        let real = acts.filter { $0.durationS >= StreakCalculator.activeFloorSeconds }
        for (id, matches) in [("consistency.dawn", real.filter { $0.startHour < dawnHourEnd }),
                              ("consistency.night", real.filter { $0.startHour >= nightHourStart })]
            where matches.count >= timeOfDayCount {
            let sealer = matches[timeOfDayCount - 1]
            out.append(Earned(awardID: id, earnedAt: sealer.date, workoutID: sealer.id))
        }

        // Training: perfect weeks, races, the return.
        out += trainingEarnings(s, calendar: calendar)

        // Strength: session count + lifetime tonnage + the set-count ladder + Full Coverage.
        let lifts = acts.filter { $0.type.isStrengthStyle }
        for (id, count) in strengthSessions where lifts.count >= count {
            let sealer = lifts[count - 1]
            out.append(Earned(awardID: id, earnedAt: sealer.date, workoutID: sealer.id))
        }
        out += accumulate(lifts, value: \.volumeKg,
                          thresholds: lifetimeVolumeKg.map { (id: $0.id, m: $0.kg) })
        out += accumulate(lifts, value: \.workingSetsD,
                          thresholds: setCounts.map { (id: $0.id, m: Double($0.count)) })
        if let sealer = coverageSealer(lifts, calendar: calendar) {
            out.append(Earned(awardID: "strength.coverage", earnedAt: sealer.date, workoutID: sealer.id))
        }

        // Body of work: lifetime sessions, any sport — real ones only (streak's qualifying floors).
        let realSessions = acts.filter(qualifies)
        for (id, count) in sessionCounts where realSessions.count >= count {
            let sealer = realSessions[count - 1]
            out.append(Earned(awardID: id, earnedAt: sealer.date, workoutID: sealer.id))
        }

        // Big weeks: weekly running volume, earned mid-week by the run that crosses the line.
        out += bigWeekEarnings(acts.filter(isRun), calendar: calendar)

        // The Ride: lifetime ladder (no e-bikes) + the century.
        out += accumulate(acts.filter(isRide), value: \.distanceM, thresholds: rideLifetimeM)
        if let hit = acts.first(where: { isRide($0) && $0.distanceM >= centuryRideM * gpsTolerance }) {
            out.append(Earned(awardID: "ride.century", earnedAt: hit.date, workoutID: hit.id))
        }

        // Time on feet: single-session moving time, any sport.
        for (id, seconds) in sessionDurationS {
            if let hit = acts.first(where: { $0.durationS >= seconds }) {
                out.append(Earned(awardID: id, earnedAt: hit.date, workoutID: hit.id))
            }
        }

        // Single-outing vert.
        for (id, meters) in singleClimbM {
            if let hit = acts.first(where: { isFoot($0) && $0.elevationGainM >= meters }) {
                out.append(Earned(awardID: id, earnedAt: hit.date, workoutID: hit.id))
            }
        }

        // Moments.
        out += momentEarnings(acts, calendar: calendar)

        return out
    }

    /// The run that first pushes a calendar week's running volume over each threshold.
    private static func bigWeekEarnings(_ runs: [Activity], calendar: Calendar) -> [Earned] {
        var out: [Earned] = []
        var weekTotals: [Date: Double] = [:]
        var remaining = weeklyRunM
        for run in runs {
            guard !remaining.isEmpty,
                  let week = calendar.dateInterval(of: .weekOfYear, for: run.date)?.start else { continue }
            weekTotals[week, default: 0] += run.distanceM
            let total = weekTotals[week]!
            while let next = remaining.first, total >= next.m {
                out.append(Earned(awardID: next.id, earnedAt: run.date, workoutID: run.id))
                remaining.removeFirst()
            }
        }
        return out
    }

    /// The session that completes all six muscle buckets within one calendar week.
    private static func coverageSealer(_ lifts: [Activity], calendar: Calendar) -> Activity? {
        var covered: [Date: Set<MuscleBucket>] = [:]
        for lift in lifts where !lift.muscleBuckets.isEmpty {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: lift.date)?.start else { continue }
            let before = covered[week, default: []]
            let after = before.union(lift.muscleBuckets)
            covered[week] = after
            if before.count < MuscleBucket.allCases.count, after.count == MuscleBucket.allCases.count {
                return lift
            }
        }
        return nil
    }

    private static func momentEarnings(_ acts: [Activity], calendar: Calendar) -> [Earned] {
        var out: [Earned] = []

        // Fresh Start — any real session on January 1.
        if let hit = acts.first(where: { a in
            qualifies(a) && calendar.component(.month, from: a.date) == 1
                && calendar.component(.day, from: a.date) == 1
        }) {
            out.append(Earned(awardID: "moments.newyear", earnedAt: hit.date, workoutID: hit.id))
        }

        // Four Seasons — a run in all four quarters of one calendar year (hemisphere-neutral).
        var quarters: [Int: Set<Int>] = [:]
        for run in acts where isRun(run) && qualifies(run) {
            let year = calendar.component(.year, from: run.date)
            let quarter = (calendar.component(.month, from: run.date) - 1) / 3
            let before = quarters[year, default: []]
            guard !before.contains(quarter) else { continue }
            quarters[year] = before.union([quarter])
            if quarters[year]?.count == 4 {
                out.append(Earned(awardID: "moments.seasons", earnedAt: run.date, workoutID: run.id))
                break
            }
        }

        // Wanderer — five starting points ≥25 km apart, greedy over run history. Pure coordinate
        // math on-device; deliberately no geocoding.
        var places: [(lat: Double, lon: Double)] = []
        for run in acts where isRun(run) {
            guard let lat = run.startLat, let lon = run.startLon else { continue }
            let isNew = places.allSatisfy {
                Geo.distance(lat1: $0.lat, lon1: $0.lon, lat2: lat, lon2: lon) >= wandererSeparationM
            }
            guard isNew else { continue }
            places.append((lat, lon))
            if places.count >= wandererPlaces {
                out.append(Earned(awardID: "moments.wanderer", earnedAt: run.date, workoutID: run.id))
                break
            }
        }

        return out
    }

    /// The count of distinct Wanderer places so far (progress reading).
    private static func wandererPlaceCount(_ acts: [Activity]) -> Int {
        var places: [(lat: Double, lon: Double)] = []
        for run in acts where isRun(run) {
            guard let lat = run.startLat, let lon = run.startLon else { continue }
            if places.allSatisfy({ Geo.distance(lat1: $0.lat, lon1: $0.lon, lat2: lat, lon2: lon) >= wandererSeparationM }) {
                places.append((lat, lon))
            }
        }
        return places.count
    }

    /// Walk activities chronologically, accumulating `value`; each threshold is earned by the
    /// activity that carries the running total across it.
    private static func accumulate(_ acts: [Activity], value: KeyPath<Activity, Double>,
                                   thresholds: [(id: String, m: Double)]) -> [Earned] {
        var out: [Earned] = []
        var total = 0.0
        var next = 0
        for a in acts {
            total += a[keyPath: value]
            while next < thresholds.count, total >= thresholds[next].m {
                out.append(Earned(awardID: thresholds[next].id, earnedAt: a.date, workoutID: a.id))
                next += 1
            }
            if next == thresholds.count { break }
        }
        return out
    }

    private static func streakEarnings(_ s: Snapshot, calendar: Calendar) -> [Earned] {
        guard let lo = s.streakDays.min(), let hi = s.streakDays.max() else { return [] }
        let todayOrdinal = StreakCalculator.localDay(s.now, calendar: calendar)
        func date(forDay day: Int) -> Date {
            calendar.date(byAdding: .day, value: day - todayOrdinal, to: s.now) ?? s.now
        }
        var out: [Earned] = []
        var run = 0, misses = 0, next = 0
        for day in lo...hi {
            if s.streakDays.contains(day) {
                run += 1
                misses = 0
                while next < streakDaysThresholds.count, run >= streakDaysThresholds[next].days {
                    out.append(Earned(awardID: streakDaysThresholds[next].id,
                                      earnedAt: date(forDay: day), workoutID: nil))
                    next += 1
                }
            } else {
                misses += 1
                if misses >= 2 { run = 0 }
            }
            if next == streakDaysThresholds.count { break }
        }
        return out
    }

    /// Completion dates of every perfect week, sorted — a finished calendar week with a real load
    /// (≥3 sessions), every one completed. `.moved` or `.missed` disqualifies: perfect means perfect.
    static func perfectWeekDates(_ s: Snapshot, calendar: Calendar) -> [Date] {
        var weeks: [Date: [PlannedFact]] = [:]
        for p in s.planned {
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: p.date) else { continue }
            weeks[interval.start, default: []].append(p)
        }
        return weeks
            .filter { start, sessions in
                guard let interval = calendar.dateInterval(of: .weekOfYear, for: start),
                      interval.end <= s.now,
                      sessions.count >= perfectWeekMinSessions else { return false }
                return sessions.allSatisfy { $0.status == .completed }
            }
            .compactMap { _, sessions in sessions.map(\.date).max() }
            .sorted()
    }

    private static func trainingEarnings(_ s: Snapshot, calendar: Calendar) -> [Earned] {
        var out: [Earned] = []

        let perfect = perfectWeekDates(s, calendar: calendar)
        for (id, count) in perfectWeeks where perfect.count >= count {
            out.append(Earned(awardID: id, earnedAt: perfect[count - 1], workoutID: nil))
        }

        // Race days: the finisher ladder over completed planned races.
        let races = s.planned.filter { $0.isRace && $0.status == .completed }.sorted { $0.date < $1.date }
        for (id, count) in raceCounts where races.count >= count {
            let sealer = races[count - 1]
            out.append(Earned(awardID: id, earnedAt: sealer.date, workoutID: sealer.workoutID))
        }

        // Race PR: the first race that beats an earlier finish at the same distance class.
        var raceBests: [RaceDistance: Double] = [:]
        for race in races {
            guard let distance = race.raceDistanceM, distance > 0,
                  let duration = race.raceDurationS, duration > 0 else { continue }
            let cls = RaceDistance.nearest(toMeters: distance)
            if let incumbent = raceBests[cls], duration < incumbent {
                out.append(Earned(awardID: "training.racepr", earnedAt: race.date, workoutID: race.workoutID))
                break
            }
            raceBests[cls] = min(raceBests[cls] ?? .infinity, duration)
        }

        // The Return: the first workout after a 14+ day silence (framed as a win, never a lapse).
        let acts = s.activities.sorted { $0.date < $1.date }
        for (prev, curr) in zip(acts, acts.dropFirst())
            where curr.date.timeIntervalSince(prev.date) >= Double(comebackGapDays) * 86_400 {
            out.append(Earned(awardID: "training.return", earnedAt: curr.date, workoutID: curr.id))
            break
        }

        return out
    }

    // MARK: Progress toward a locked award

    static func progress(toward award: Award, in s: Snapshot,
                         calendar: Calendar = .current) -> Progress? {
        let acts = s.activities
        func frac(_ current: Double, _ target: Double, _ unit: Progress.Unit) -> Progress {
            Progress(fraction: target > 0 ? min(1, max(0, current / target)) : 0,
                     current: current, target: target, unit: unit)
        }

        if let t = lifetimeDistanceM.first(where: { $0.id == award.id }) {
            return frac(acts.filter(isRun).reduce(0) { $0 + $1.distanceM }, t.m, .meters)
        }
        if award.id == "longrun.first" {
            return frac(acts.contains { isRun($0) && $0.distanceM >= firstRunFloorM } ? 1 : 0, 1, .count)
        }
        if let t = singleRunM.first(where: { $0.id == award.id }) {
            let best = acts.filter(isRun).map(\.distanceM).max() ?? 0
            return frac(best, t.m * gpsTolerance, .meters)
        }
        if let t = lifetimeClimbM.first(where: { $0.id == award.id }) {
            return frac(acts.filter(isFoot).reduce(0) { $0 + $1.elevationGainM }, t.m, .meters)
        }
        if let t = benchmarkS.first(where: { $0.id == award.id }) {
            // Times improve downward: the fraction is target/best, so 26:00 against sub-25 ≈ 0.96.
            let best = s.records.filter { $0.type == t.type && $0.value > 0 }.map(\.value).min()
            guard let best else { return Progress(fraction: 0, current: 0, target: t.s, unit: .seconds) }
            return Progress(fraction: min(1, t.s / best), current: best, target: t.s, unit: .seconds)
        }
        if let t = streakDaysThresholds.first(where: { $0.id == award.id }) {
            let today = StreakCalculator.localDay(s.now, calendar: calendar)
            let current = StreakCalculator.currentStreak(countingDays: s.streakDays, today: today)
            return frac(Double(current), Double(t.days), .days)
        }
        if award.id == "consistency.dawn" || award.id == "consistency.night" {
            let real = acts.filter { $0.durationS >= StreakCalculator.activeFloorSeconds }
            let count = award.id == "consistency.dawn"
                ? real.count { $0.startHour < dawnHourEnd }
                : real.count { $0.startHour >= nightHourStart }
            return frac(Double(count), Double(timeOfDayCount), .count)
        }
        if let t = perfectWeeks.first(where: { $0.id == award.id }) {
            let count = perfectWeekDates(s, calendar: calendar).count
            return frac(Double(count), Double(t.weeks), .count)
        }
        if let t = raceCounts.first(where: { $0.id == award.id }) {
            let done = s.planned.count { $0.isRace && $0.status == .completed }
            return frac(Double(done), Double(t.count), .count)
        }
        if award.id == "training.racepr" || award.id == "training.return" || award.id == "moments.newyear" {
            return frac(0, 1, .count)   // binary moments — no meaningful partial
        }
        if let t = strengthSessions.first(where: { $0.id == award.id }) {
            return frac(Double(acts.count { $0.type.isStrengthStyle }), Double(t.count), .count)
        }
        if let t = lifetimeVolumeKg.first(where: { $0.id == award.id }) {
            let total = acts.filter { $0.type.isStrengthStyle }.reduce(0) { $0 + $1.volumeKg }
            return frac(total, t.kg, .kilograms)
        }
        if let t = setCounts.first(where: { $0.id == award.id }) {
            let total = acts.filter { $0.type.isStrengthStyle }.reduce(0) { $0 + $1.workingSets }
            return frac(Double(total), Double(t.count), .count)
        }
        if award.id == "strength.coverage" {
            var covered: [Date: Set<MuscleBucket>] = [:]
            for lift in acts where lift.type.isStrengthStyle && !lift.muscleBuckets.isEmpty {
                guard let week = calendar.dateInterval(of: .weekOfYear, for: lift.date)?.start else { continue }
                covered[week, default: []].formUnion(lift.muscleBuckets)
            }
            let best = covered.values.map(\.count).max() ?? 0
            return frac(Double(best), Double(MuscleBucket.allCases.count), .count)
        }
        if let t = sessionCounts.first(where: { $0.id == award.id }) {
            return frac(Double(acts.count(where: qualifies)), Double(t.count), .count)
        }
        if let t = weeklyRunM.first(where: { $0.id == award.id }) {
            var weekTotals: [Date: Double] = [:]
            for run in acts where isRun(run) {
                guard let week = calendar.dateInterval(of: .weekOfYear, for: run.date)?.start else { continue }
                weekTotals[week, default: 0] += run.distanceM
            }
            return frac(weekTotals.values.max() ?? 0, t.m, .meters)
        }
        if let t = rideLifetimeM.first(where: { $0.id == award.id }) {
            return frac(acts.filter(isRide).reduce(0) { $0 + $1.distanceM }, t.m, .meters)
        }
        if award.id == "ride.century" {
            let best = acts.filter(isRide).map(\.distanceM).max() ?? 0
            return frac(best, centuryRideM * gpsTolerance, .meters)
        }
        if let t = sessionDurationS.first(where: { $0.id == award.id }) {
            return frac(acts.map(\.durationS).max() ?? 0, t.s, .seconds)
        }
        if let t = singleClimbM.first(where: { $0.id == award.id }) {
            let best = acts.filter(isFoot).map(\.elevationGainM).max() ?? 0
            return frac(best, t.m, .meters)
        }
        if award.id == "moments.seasons" {
            var quarters: [Int: Set<Int>] = [:]
            for run in acts where isRun(run) && qualifies(run) {
                let year = calendar.component(.year, from: run.date)
                quarters[year, default: []].insert((calendar.component(.month, from: run.date) - 1) / 3)
            }
            return frac(Double(quarters.values.map(\.count).max() ?? 0), 4, .count)
        }
        if award.id == "moments.wanderer" {
            return frac(Double(wandererPlaceCount(acts)), Double(wandererPlaces), .count)
        }
        return nil
    }
}
