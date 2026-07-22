import Foundation

/// One award in the trophy room — a fixed, curated definition (never generated at runtime).
/// `id` is the persistence key on `EarnedAward`; it must never change once shipped.
struct Award: Identifiable, Sendable, Equatable, Hashable {
    /// The twelve shelves of the trophy room. Order here is display order.
    enum Collection: String, CaseIterable, Sendable, Identifiable {
        case distance, longRun, bigWeeks, speed, endurance, climb, ride
        case consistency, training, strength, sessions, moments
        var id: String { rawValue }

        var title: String {
            switch self {
            case .distance: "The Distance"
            case .longRun: "The Long Run"
            case .bigWeeks: "Big Weeks"
            case .speed: "Speed"
            case .endurance: "Time on Feet"
            case .climb: "The Climb"
            case .ride: "The Ride"
            case .consistency: "Consistency"
            case .training: "Training"
            case .strength: "Strength"
            case .sessions: "Body of Work"
            case .moments: "Moments"
            }
        }

        /// One quiet line under the shelf header — what this collection measures.
        var subtitle: String {
            switch self {
            case .distance: "Lifetime kilometers of running"
            case .longRun: "Your farthest single runs"
            case .bigWeeks: "Running volume, one week at a time"
            case .speed: "Benchmark times, ratified by GPS"
            case .endurance: "Your longest single sessions"
            case .climb: "Meters climbed on foot"
            case .ride: "Kilometers in the saddle"
            case .consistency: "Days in a row, kept moving"
            case .training: "The work the plan asked for"
            case .strength: "Sessions and tonnage under the bar"
            case .sessions: "Every workout, every sport, counted"
            case .moments: "The ones with a story"
            }
        }
    }

    let id: String
    let collection: Collection
    /// Position within the collection (drives gallery ordering and "next up" selection).
    let tier: Int
    let name: String
    /// The earn condition, in plain words ("Run 100 kilometers, lifetime").
    let requirement: String
    let glyph: String
    /// The short value struck into the coin face ("100", "SUB 20", "365").
    let engraving: String
    /// The summit of its collection — earns the iridescent face, not just the rim.
    let isCrown: Bool

    init(_ id: String, _ collection: Collection, tier: Int, name: String,
         requirement: String, glyph: String, engraving: String, isCrown: Bool = false) {
        self.id = id
        self.collection = collection
        self.tier = tier
        self.name = name
        self.requirement = requirement
        self.glyph = glyph
        self.engraving = engraving
        self.isCrown = isCrown
    }
}

/// The fixed award catalog — the awards system's single source of truth. Detection thresholds
/// live in `AwardsEngine` next to the logic that reads them; the two are pinned together by
/// `AwardsEngineTests` so a catalog entry can never drift from its rule.
enum AwardsCatalog {

    static let all: [Award] = distance + longRun + bigWeeks + speed + endurance + climb + ride
        + consistency + training + strength + sessions + moments

    private static let byID: [String: Award] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func award(_ id: String) -> Award? { byID[id] }

    static func awards(in collection: Award.Collection) -> [Award] {
        all.filter { $0.collection == collection }
    }

    // MARK: The shelves

    /// Lifetime running distance. Kilometer-defined worldwide (like every classic distance
    /// milestone) — display may convert, the thresholds don't.
    static let distance: [Award] = [
        Award("distance.50", .distance, tier: 1, name: "First Fifty",
              requirement: "Run 50 kilometers, lifetime", glyph: distanceGlyph, engraving: "50"),
        Award("distance.100", .distance, tier: 2, name: "Century Club",
              requirement: "Run 100 kilometers, lifetime", glyph: distanceGlyph, engraving: "100"),
        Award("distance.250", .distance, tier: 3, name: "250 Club",
              requirement: "Run 250 kilometers, lifetime", glyph: distanceGlyph, engraving: "250"),
        Award("distance.500", .distance, tier: 4, name: "500 Club",
              requirement: "Run 500 kilometers, lifetime", glyph: distanceGlyph, engraving: "500"),
        Award("distance.1000", .distance, tier: 5, name: "1,000 Club",
              requirement: "Run 1,000 kilometers, lifetime", glyph: distanceGlyph, engraving: "1,000"),
        Award("distance.2500", .distance, tier: 6, name: "2,500 Club",
              requirement: "Run 2,500 kilometers, lifetime", glyph: distanceGlyph, engraving: "2,500"),
        Award("distance.5000", .distance, tier: 7, name: "5,000 Club",
              requirement: "Run 5,000 kilometers, lifetime", glyph: distanceGlyph, engraving: "5,000",
              isCrown: true),
    ]
    private static let distanceGlyph = "point.bottomleft.forward.to.point.topright.scurvepath"

    /// Single-run distance firsts — the classic finisher ladder.
    static let longRun: [Award] = [
        Award("longrun.first", .longRun, tier: 1, name: "First Steps",
              requirement: "Complete your first run", glyph: "figure.run", engraving: "FIRST"),
        Award("longrun.5k", .longRun, tier: 2, name: "The 5K",
              requirement: "Run 5 kilometers in a single run", glyph: "figure.run", engraving: "5K"),
        Award("longrun.10k", .longRun, tier: 3, name: "The 10K",
              requirement: "Run 10 kilometers in a single run", glyph: "figure.run", engraving: "10K"),
        Award("longrun.half", .longRun, tier: 4, name: "The Half",
              requirement: "Cover the half-marathon distance in one run", glyph: "figure.run", engraving: "21.1"),
        Award("longrun.marathon", .longRun, tier: 5, name: "The Marathon",
              requirement: "Cover the marathon distance in one run", glyph: "figure.run", engraving: "42.2"),
        Award("longrun.ultra", .longRun, tier: 6, name: "Ultra",
              requirement: "Run 50 kilometers in a single run", glyph: "figure.run", engraving: "50K",
              isCrown: true),
    ]

    /// Lifetime elevation gain on foot (runs, trails, hikes, walks).
    static let climb: [Award] = [
        Award("climb.1000", .climb, tier: 1, name: "First Ascent",
              requirement: "Climb 1,000 meters, lifetime", glyph: "mountain.2.fill", engraving: "1K"),
        Award("climb.5000", .climb, tier: 2, name: "Mountain Legs",
              requirement: "Climb 5,000 meters, lifetime", glyph: "mountain.2.fill", engraving: "5K"),
        Award("climb.everest", .climb, tier: 3, name: "Everest",
              requirement: "Climb 8,849 meters — the height of Everest", glyph: "mountain.2.fill", engraving: "8,849"),
        Award("climb.25000", .climb, tier: 4, name: "High Country",
              requirement: "Climb 25,000 meters, lifetime", glyph: "mountain.2.fill", engraving: "25K"),
        Award("climb.50000", .climb, tier: 5, name: "Skyrunner",
              requirement: "Climb 50,000 meters, lifetime", glyph: "mountain.2.fill", engraving: "50K"),
        Award("climb.100000", .climb, tier: 6, name: "Above the Clouds",
              requirement: "Climb 100,000 meters, lifetime", glyph: "mountain.2.fill", engraving: "100K",
              isCrown: true),
        // Single-outing vert — the specials after the lifetime ladder.
        Award("climb.single500", .climb, tier: 7, name: "Hill Day",
              requirement: "Climb 500 meters in one workout", glyph: "mountain.2.fill", engraving: "500"),
        Award("climb.single1000", .climb, tier: 8, name: "Vert Hunter",
              requirement: "Climb 1,000 meters in one workout", glyph: "mountain.2.fill", engraving: "1,000"),
    ]

    /// Benchmark times, read from the ratified record book (GPS fastest-window PRs).
    static let speed: [Award] = [
        Award("speed.5k.sub30", .speed, tier: 1, name: "Breaking 30",
              requirement: "Run 5K under 30 minutes", glyph: "bolt.fill", engraving: "SUB 30"),
        Award("speed.5k.sub25", .speed, tier: 2, name: "Breaking 25",
              requirement: "Run 5K under 25 minutes", glyph: "bolt.fill", engraving: "SUB 25"),
        Award("speed.5k.sub20", .speed, tier: 3, name: "Breaking 20",
              requirement: "Run 5K under 20 minutes", glyph: "bolt.fill", engraving: "SUB 20",
              isCrown: true),
        Award("speed.10k.sub60", .speed, tier: 4, name: "The Hour",
              requirement: "Run 10K under 60 minutes", glyph: "timer", engraving: "SUB 60"),
        Award("speed.10k.sub50", .speed, tier: 5, name: "Fifty Flat",
              requirement: "Run 10K under 50 minutes", glyph: "timer", engraving: "SUB 50"),
        Award("speed.10k.sub45", .speed, tier: 6, name: "Forty-Five",
              requirement: "Run 10K under 45 minutes", glyph: "timer", engraving: "SUB 45",
              isCrown: true),
        // Half + marathon benchmarks read the fastestHalf/fastestMarathon record types — every
        // series ends in a crown, so each racing distance has a summit.
        Award("speed.half.sub2", .speed, tier: 7, name: "Breaking Two",
              requirement: "Run a half marathon under 2 hours", glyph: "bolt.fill", engraving: "SUB 2:00"),
        Award("speed.half.sub145", .speed, tier: 8, name: "One Forty-Five",
              requirement: "Run a half marathon under 1:45", glyph: "bolt.fill", engraving: "SUB 1:45"),
        Award("speed.half.sub130", .speed, tier: 9, name: "The Ninety",
              requirement: "Run a half marathon under 90 minutes", glyph: "bolt.fill", engraving: "SUB 1:30",
              isCrown: true),
        Award("speed.mara.sub4", .speed, tier: 10, name: "Breaking Four",
              requirement: "Run a marathon under 4 hours", glyph: "timer", engraving: "SUB 4:00"),
        Award("speed.mara.sub330", .speed, tier: 11, name: "Three Thirty",
              requirement: "Run a marathon under 3:30", glyph: "timer", engraving: "SUB 3:30"),
        Award("speed.mara.sub3", .speed, tier: 12, name: "Breaking Three",
              requirement: "Run a marathon under 3 hours", glyph: "timer", engraving: "SUB 3:00",
              isCrown: true),
    ]

    /// Streaks (the same shame-free 2-day-grace rule the flame uses) + time-of-day specials.
    static let consistency: [Award] = [
        Award("streak.7", .consistency, tier: 1, name: "One Week Strong",
              requirement: "Keep a 7-day streak", glyph: "flame.fill", engraving: "7"),
        Award("streak.14", .consistency, tier: 2, name: "Two Weeks Deep",
              requirement: "Keep a 14-day streak", glyph: "flame.fill", engraving: "14"),
        Award("streak.30", .consistency, tier: 3, name: "The Month",
              requirement: "Keep a 30-day streak", glyph: "flame.fill", engraving: "30"),
        Award("streak.60", .consistency, tier: 4, name: "Sixty Days",
              requirement: "Keep a 60-day streak", glyph: "flame.fill", engraving: "60"),
        Award("streak.100", .consistency, tier: 5, name: "Century Streak",
              requirement: "Keep a 100-day streak", glyph: "flame.fill", engraving: "100"),
        Award("streak.365", .consistency, tier: 6, name: "A Year of Motion",
              requirement: "Keep the streak for a full year", glyph: "flame.fill", engraving: "365",
              isCrown: true),
        Award("consistency.dawn", .consistency, tier: 7, name: "Dawn Patrol",
              requirement: "Start 5 workouts before 6 a.m.", glyph: "sunrise.fill", engraving: "DAWN"),
        Award("consistency.night", .consistency, tier: 8, name: "Night Shift",
              requirement: "Start 5 workouts after 9 p.m.", glyph: "moon.stars.fill", engraving: "NIGHT"),
    ]

    /// Doing the work the plan prescribed — and coming back when life got in the way.
    static let training: [Award] = [
        Award("training.perfectweek", .training, tier: 1, name: "Perfect Week",
              requirement: "Complete every planned session in a week", glyph: "checkmark.seal.fill", engraving: "1"),
        Award("training.perfectweek4", .training, tier: 2, name: "Dialed In",
              requirement: "Complete 4 perfect weeks", glyph: "checkmark.seal.fill", engraving: "4"),
        Award("training.perfectweek12", .training, tier: 3, name: "Metronome",
              requirement: "Complete 12 perfect weeks", glyph: "metronome.fill", engraving: "12",
              isCrown: true),
        Award("training.race", .training, tier: 4, name: "Race Day",
              requirement: "Finish a race on your plan", glyph: "flag.checkered", engraving: "RACE"),
        Award("training.race3", .training, tier: 5, name: "Racing Season",
              requirement: "Finish 3 races on your plan", glyph: "flag.checkered", engraving: "×3"),
        Award("training.race10", .training, tier: 6, name: "Serial Racer",
              requirement: "Finish 10 races on your plan", glyph: "flag.checkered", engraving: "×10"),
        Award("training.racepr", .training, tier: 7, name: "Race PR",
              requirement: "Beat your own time at a race distance", glyph: "trophy.fill", engraving: "PR"),
        Award("training.return", .training, tier: 8, name: "The Return",
              requirement: "Train again after two weeks away — the hardest one", glyph: "arrow.uturn.forward",
              engraving: "BACK"),
    ]

    /// The supporting pillar: showing up under the bar, and what it adds up to.
    static let strength: [Award] = [
        Award("strength.first", .strength, tier: 1, name: "First Lift",
              requirement: "Complete your first strength session", glyph: "dumbbell.fill", engraving: "FIRST"),
        Award("strength.10", .strength, tier: 2, name: "Ten Strong",
              requirement: "Complete 10 strength sessions", glyph: "dumbbell.fill", engraving: "10"),
        Award("strength.50", .strength, tier: 3, name: "Fifty Strong",
              requirement: "Complete 50 strength sessions", glyph: "dumbbell.fill", engraving: "50"),
        Award("strength.100", .strength, tier: 4, name: "Iron Hundred",
              requirement: "Complete 100 strength sessions", glyph: "dumbbell.fill", engraving: "100"),
        Award("volume.100t", .strength, tier: 5, name: "100 Tonnes",
              requirement: "Lift 100,000 kg, lifetime", glyph: "scalemass.fill", engraving: "100 T"),
        Award("volume.500t", .strength, tier: 6, name: "500 Tonnes",
              requirement: "Lift 500,000 kg, lifetime", glyph: "scalemass.fill", engraving: "500 T"),
        Award("volume.million", .strength, tier: 7, name: "The Million",
              requirement: "Lift 1,000,000 kg, lifetime", glyph: "scalemass.fill", engraving: "1M",
              isCrown: true),
        Award("strength.sets1000", .strength, tier: 8, name: "A Thousand Sets",
              requirement: "Log 1,000 working sets, lifetime", glyph: "square.stack.3d.up.fill",
              engraving: "1,000"),
        Award("strength.sets10000", .strength, tier: 9, name: "Ten Thousand",
              requirement: "Log 10,000 working sets, lifetime", glyph: "square.stack.3d.up.fill",
              engraving: "10K"),
        Award("strength.coverage", .strength, tier: 10, name: "Full Coverage",
              requirement: "Train chest, back, shoulders, arms, legs, and core in one week",
              glyph: "figure.arms.open", engraving: "ALL"),
    ]

    /// Weekly running volume — the classic big-week ladder (Monday through Sunday, local weeks).
    static let bigWeeks: [Award] = [
        Award("week.25", .bigWeeks, tier: 1, name: "25K Week",
              requirement: "Run 25 km in one week", glyph: "chart.bar.fill", engraving: "25"),
        Award("week.40", .bigWeeks, tier: 2, name: "40K Week",
              requirement: "Run 40 km in one week", glyph: "chart.bar.fill", engraving: "40"),
        Award("week.60", .bigWeeks, tier: 3, name: "60K Week",
              requirement: "Run 60 km in one week", glyph: "chart.bar.fill", engraving: "60"),
        Award("week.80", .bigWeeks, tier: 4, name: "80K Week",
              requirement: "Run 80 km in one week", glyph: "chart.bar.fill", engraving: "80"),
        Award("week.100", .bigWeeks, tier: 5, name: "100K Week",
              requirement: "Run 100 km in one week", glyph: "chart.bar.fill", engraving: "100",
              isCrown: true),
    ]

    /// Single-session moving time — any sport. The long-haul ladder for the ultra-curious.
    static let endurance: [Award] = [
        Award("endurance.1h", .endurance, tier: 1, name: "Sixty Minutes",
              requirement: "Train for 1 hour in one session", glyph: "hourglass", engraving: "1 HR"),
        Award("endurance.2h", .endurance, tier: 2, name: "The Double",
              requirement: "Train for 2 hours in one session", glyph: "hourglass", engraving: "2 HR"),
        Award("endurance.3h", .endurance, tier: 3, name: "The Triple",
              requirement: "Train for 3 hours in one session", glyph: "hourglass", engraving: "3 HR"),
        Award("endurance.4h", .endurance, tier: 4, name: "The Long Haul",
              requirement: "Train for 4 hours in one session", glyph: "hourglass", engraving: "4 HR",
              isCrown: true),
    ]

    /// Cycling finally earns metal. E-bike rides stay out of the distance ladders (motor-assisted
    /// kilometers aren't the same currency) — they still count toward streaks and sessions.
    static let ride: [Award] = [
        Award("ride.100", .ride, tier: 1, name: "Wheels Up",
              requirement: "Ride 100 km, lifetime", glyph: "bicycle", engraving: "100"),
        Award("ride.century", .ride, tier: 2, name: "Century Ride",
              requirement: "Ride 100 km in a single ride", glyph: "bicycle", engraving: "100K"),
        Award("ride.500", .ride, tier: 3, name: "Half Grand",
              requirement: "Ride 500 km, lifetime", glyph: "bicycle", engraving: "500"),
        Award("ride.1000", .ride, tier: 4, name: "Grand Tour",
              requirement: "Ride 1,000 km, lifetime", glyph: "bicycle", engraving: "1,000"),
        Award("ride.5000", .ride, tier: 5, name: "The Long Road",
              requirement: "Ride 5,000 km, lifetime", glyph: "bicycle", engraving: "5,000",
              isCrown: true),
    ]

    /// Lifetime workouts, any sport — the deepest retention ladder in the room. Only real
    /// sessions count (the same qualifying floors the streak uses).
    static let sessions: [Award] = [
        Award("sessions.10", .sessions, tier: 1, name: "Ten Deep",
              requirement: "Log 10 workouts", glyph: "square.grid.3x3.fill", engraving: "10"),
        Award("sessions.50", .sessions, tier: 2, name: "Fifty Deep",
              requirement: "Log 50 workouts", glyph: "square.grid.3x3.fill", engraving: "50"),
        Award("sessions.100", .sessions, tier: 3, name: "The Hundred",
              requirement: "Log 100 workouts", glyph: "square.grid.3x3.fill", engraving: "100"),
        Award("sessions.250", .sessions, tier: 4, name: "Two Fifty",
              requirement: "Log 250 workouts", glyph: "square.grid.3x3.fill", engraving: "250"),
        Award("sessions.500", .sessions, tier: 5, name: "Five Hundred",
              requirement: "Log 500 workouts", glyph: "square.grid.3x3.fill", engraving: "500"),
        Award("sessions.1000", .sessions, tier: 6, name: "The Thousand",
              requirement: "Log 1,000 workouts", glyph: "square.grid.3x3.fill", engraving: "1,000",
              isCrown: true),
    ]

    /// The ones with a story. Wanderer counts distinct starting places ≥25 km apart — pure
    /// coordinate math, computed on-device; no geocoding, nothing leaves the phone.
    static let moments: [Award] = [
        Award("moments.newyear", .moments, tier: 1, name: "Fresh Start",
              requirement: "Train on New Year's Day", glyph: "sparkles", engraving: "JAN 1"),
        Award("moments.seasons", .moments, tier: 2, name: "Four Seasons",
              requirement: "Run in every season of one year", glyph: "leaf.fill", engraving: "×4"),
        Award("moments.wanderer", .moments, tier: 3, name: "Wanderer",
              requirement: "Run in 5 places at least 25 km apart", glyph: "map.fill", engraving: "×5",
              isCrown: true),
    ]
}
