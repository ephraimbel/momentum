import Foundation

// Unified domain enums (PRD §8.7). Stored as raw strings for SwiftData/Supabase portability.

enum WorkoutType: String, Codable, Sendable, CaseIterable {
    // Foot (GPS)
    case run, trailRun, walk, hike
    // Cycle (GPS)
    case ride, mountainBikeRide, gravelRide, eBikeRide
    // Gym (strength logger)
    case strength, crossfit, hiit
    // Timed (stopwatch — no GPS, no sets)
    case tennis, soccer, basketball, golf
    case yoga, pilates
    // Water & endurance machines (timed capture — pool/erg, no GPS)
    case swimming, rowing
    case other
}

/// Groups for the "Choose a Sport" picker (Strava-style).
enum SportCategory: String, CaseIterable, Identifiable {
    case foot, cycle, water, gym, sport, mind, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .foot: "Foot Sports"
        case .cycle: "Cycle Sports"
        case .water: "Water Sports"
        case .gym: "Gym & Strength"
        case .sport: "Sports"
        case .mind: "Mind & Body"
        case .other: "Other"
        }
    }
}
enum Discipline: String, Codable, Sendable, CaseIterable { case running, cycling, walking, strength }

/// A target race the plan points at (drives long-run progression + taper). Onboarding captures one
/// for "run a race" goals; the engine reads `raceDistanceM`.
enum RaceDistance: String, Codable, Sendable, CaseIterable, Identifiable {
    case fiveK, tenK, half, marathon
    var id: String { rawValue }
    var meters: Double {
        switch self { case .fiveK: 5_000; case .tenK: 10_000; case .half: 21_097.5; case .marathon: 42_195 }
    }
    var label: String {
        switch self { case .fiveK: "5K"; case .tenK: "10K"; case .half: "Half marathon"; case .marathon: "Marathon" }
    }
    /// The closest preset to a stored meters value (for display of a custom distance).
    static func nearest(toMeters m: Double) -> RaceDistance {
        allCases.min { abs($0.meters - m) < abs($1.meters - m) } ?? .fiveK
    }
}

/// Optional, used to refine load/HR/figure tailoring. "Prefer not to say" → nil.
enum BiologicalSex: String, Codable, Sendable, CaseIterable, Identifiable {
    case male, female, other
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
enum Goal: String, Codable, Sendable, CaseIterable {
    case loseFat, buildMuscle, getStronger, raceDistance, endurance, generalFitness, stayConsistent
}
enum Equipment: String, Codable, Sendable, CaseIterable { case fullGym, dumbbellsOnly, homeMinimal, bodyweight }
enum ExperienceLevel: String, Codable, Sendable, CaseIterable { case new, some, experienced }
enum MuscleGroup: String, Codable, Sendable, CaseIterable {
    case chest, back, shoulders, biceps, triceps, forearms, quads, hamstrings, glutes, calves, core, fullBody
}
enum EquipmentType: String, Codable, Sendable, CaseIterable {
    case barbell, dumbbell, machine, cable, kettlebell, bodyweight, band
}
enum ExerciseCategory: String, Codable, Sendable, CaseIterable { case compound, isolation, cardio }
enum TrackingMode: String, Codable, Sendable, CaseIterable { case weightReps, repsOnly, time, distance }
enum SetType: String, Codable, Sendable, CaseIterable { case working, warmup, drop, failure, amrap }
enum RunType: String, Codable, Sendable, CaseIterable {
    case easy, long, tempo, intervals, recovery, race, freeRun
}
enum SessionStatus: String, Codable, Sendable, CaseIterable { case planned, completed, missed, moved }
enum PRType: String, Codable, Sendable, CaseIterable {
    case fastest1k, fastest5k, fastest10k, longestRun, longestDuration
    case heaviestWeight, bestE1RM, repMax, bestSetVolume, bestSessionVolume
}
enum WorkoutPrivacy: String, Codable, Sendable, CaseIterable {
    case `private`, friends, `public`

    /// User-facing label for the visibility picker.
    var label: String {
        switch self {
        case .private: "Only me"
        case .friends: "Followers"
        case .public: "Everyone"
        }
    }

    var icon: String {
        switch self {
        case .private: "lock.fill"
        case .friends: "person.2.fill"
        case .public: "globe"
        }
    }
}

/// How precisely an opted-in athlete's location may ever be shown publicly (PRD §11 — fuzzed; never
/// precise coordinates). See docs/SOCIAL-LAYER.md.
enum LocationGranularity: String, Codable, Sendable, CaseIterable {
    case off, city, region

    var label: String {
        switch self {
        case .off: "Hidden"
        case .city: "City"
        case .region: "Region"
        }
    }
}

extension WorkoutType: Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .run: "Run"
        case .trailRun: "Trail Run"
        case .walk: "Walk"
        case .hike: "Hike"
        case .ride: "Ride"
        case .mountainBikeRide: "Mountain Bike Ride"
        case .gravelRide: "Gravel Ride"
        case .eBikeRide: "E-Bike Ride"
        case .strength: "Weight Training"
        case .crossfit: "Crossfit"
        case .hiit: "HIIT"
        case .tennis: "Tennis"
        case .soccer: "Soccer"
        case .basketball: "Basketball"
        case .golf: "Golf"
        case .yoga: "Yoga"
        case .pilates: "Pilates"
        case .swimming: "Swim"
        case .rowing: "Rowing"
        case .other: "Workout"
        }
    }

    var systemImage: String {
        switch self {
        case .run, .trailRun: "figure.run"
        case .walk: "figure.walk"
        case .hike: "figure.hiking"
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide: "bicycle"
        case .strength: "dumbbell.fill"
        case .crossfit: "figure.cross.training"
        case .hiit: "figure.highintensity.intervaltraining"
        case .tennis: "figure.tennis"
        case .soccer: "figure.soccer"
        case .basketball: "figure.basketball"
        case .golf: "figure.golf"
        case .yoga: "figure.yoga"
        case .pilates: "figure.pilates"
        case .swimming: "figure.pool.swim"
        case .rowing: "figure.rower"
        case .other: "figure.mixed.cardio"
        }
    }

    /// Gym sports capture via the strength set-logger (no GPS).
    var isStrengthStyle: Bool {
        switch self {
        case .strength, .crossfit, .hiit: true
        default: false
        }
    }
    /// Timed sports capture via a simple stopwatch — no GPS route, no logged sets.
    var isTimed: Bool {
        switch self {
        case .tennis, .soccer, .basketball, .golf, .yoga, .pilates, .swimming, .rowing, .other: true
        default: false
        }
    }
    /// A GPS/map workout (run/ride/walk family) — carries a `gps` payload. The three capture modes
    /// are mutually exclusive: `isGPS`, `isStrengthStyle`, `isTimed`.
    var isGPS: Bool { !isStrengthStyle && !isTimed }

    /// Maps each sport to one of the four planning/analytics disciplines (§8.7 notes). Trail runs roll
    /// up to running; bike variants to cycling; walk/hike to walking; gym to strength. Timed sports
    /// have no planning discipline (they're never planned) — bucketed by feel, used only inertly.
    var discipline: Discipline {
        switch self {
        case .run, .trailRun: .running
        case .walk, .hike: .walking
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide: .cycling
        case .strength, .crossfit, .hiit: .strength
        case .tennis, .soccer, .basketball: .running
        case .swimming, .rowing: .running   // endurance cardio — inert bucket (timed, never planned)
        case .golf, .yoga, .pilates, .other: .strength
        }
    }

    /// Grouping for the sport picker.
    var category: SportCategory {
        switch self {
        case .run, .trailRun, .walk, .hike: .foot
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide: .cycle
        case .strength, .crossfit, .hiit: .gym
        case .tennis, .soccer, .basketball, .golf: .sport
        case .yoga, .pilates: .mind
        case .swimming, .rowing: .water
        case .other: .other
        }
    }
}
