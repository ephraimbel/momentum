import Foundation

// Unified domain enums (PRD §8.7). Stored as raw strings for SwiftData/Supabase portability.

/// For a hybrid (run + lift) athlete, where the emphasis sits — biases the run/lift day split so the
/// plan matches how they actually think of themselves, rather than being inferred from the goal alone.
enum HybridPriority: String, Codable, Sendable, CaseIterable {
    case running, balanced, lifting
    /// Fraction of the week's training days given to lifting.
    var liftFraction: Double {
        switch self {
        case .running: 0.35
        case .balanced: 0.5
        case .lifting: 0.6
        }
    }
}

/// How the plan composes strength days (2026-08-20, user call: athletes want their split, not
/// just full body). `.coach` keeps the engine's day-count default — full body up to 3 lift days,
/// upper/lower at 4, push/pull/legs at 5+ — bit-identical to every plan built before the choice
/// existed. The explicit styles override that table at ANY day count; with fewer than 2 lift
/// days a split honestly collapses to full body (one "push day" a week would mean legs never
/// train). Bro split deliberately not offered (owner call — parked).
enum StrengthSplitStyle: String, Codable, Sendable, CaseIterable {
    case coach, fullBody, upperLower, pushPullLegs
}

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

extension WorkoutType {
    /// The sport bucket a discipline maps to when nothing more precise is known.
    static func forDiscipline(_ d: Discipline) -> WorkoutType {
        switch d { case .strength: .strength; case .cycling: .ride; case .walking: .walk; case .running: .run }
    }

    // `forPlanned(_:)` lives in TrainingPlan.swift, not here: this file is compiled into the watch
    // and widget targets too, and they don't build PlannedSession.
}

/// A target race the plan points at (drives long-run progression + taper). Onboarding captures one
/// for "run a race" goals; the engine reads `raceDistanceM`.
enum RaceDistance: String, Codable, Sendable, CaseIterable, Identifiable {
    case fiveK, tenK, half, marathon, fiftyK
    var id: String { rawValue }
    var meters: Double {
        switch self {
        case .fiveK: 5_000; case .tenK: 10_000; case .half: 21_097.5
        case .marathon: 42_195; case .fiftyK: 50_000
        }
    }
    var label: String {
        switch self {
        case .fiveK: "5K"; case .tenK: "10K"; case .half: "Half marathon"
        case .marathon: "Marathon"; case .fiftyK: "50K ultra"
        }
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
/// Macrocycle phase of a plan week (ENDURANCE-FOCUS §6.1) — persisted per week so the Plan page reads
/// like a coached block (Base → Build → Peak → Taper), not a list of runs.
enum PlanPhase: String, Codable, Sendable {
    case base, build, peak, recovery, taper
    var label: String {
        switch self {
        case .base: "Base"; case .build: "Build"; case .peak: "Peak"
        case .recovery: "Recovery week"; case .taper: "Taper"
        }
    }
    /// One line of coach's intent for the week header.
    var intent: String {
        switch self {
        case .base: "Laying the foundation — easy volume first"
        case .build: "The work phase — fitness is built here"
        case .peak: "Biggest week, race-specific work — hold steady"
        case .recovery: "Planned down week — absorb the training"
        case .taper: "Sharpening up — arrive fresh"
        }
    }
}

/// Common running injury areas (ENDURANCE-FOCUS §8.2) — captured at onboarding so the plan starts
/// protective, and reused by the injury-report loop. Body areas, never diagnoses.
enum InjuryArea: String, Codable, Sendable, CaseIterable, Identifiable {
    case shins, knee, itBand, ankle, achilles, foot, calf, hamstring, hip, back
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shins: "Shins"; case .knee: "Knee"; case .itBand: "IT band"; case .ankle: "Ankle"
        case .achilles: "Achilles"; case .foot: "Foot / plantar"; case .calf: "Calf"
        case .hamstring: "Hamstring"; case .hip: "Hip"; case .back: "Lower back"
        }
    }
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
    // Workout variety (running-excellence): speed play, hill reps, neuromuscular strides, and a
    // progression run that finishes fast. Single-word raw values display cleanly via `.capitalized`.
    case fartlek, hills, strides, progression

    /// The athlete-facing name (2026-08-28, owner call: a plan is a simple thing to follow).
    /// Coach jargon stays out of the app's mouth — a tempo is a "Steady run", intervals are
    /// "Repeats". The raw values are storage and never displayed. Library workouts keep their
    /// own titles; this is what a PLAN calls a session.
    var planTitle: String {
        switch self {
        case .easy: "Easy run"
        case .long: "Long run"
        case .tempo: "Steady run"
        case .intervals: "Repeats"
        case .recovery: "Recovery run"
        case .race: "Race day"
        case .freeRun: "Run"
        case .fartlek: "Easy run with pick-ups"
        case .hills: "Hill repeats"
        case .strides: "Pick-ups"
        case .progression: "Progression run"
        }
    }

    /// The quality (hard) sessions — used for recovery scheduling, pace recalibration, and Pace Insights.
    var isQuality: Bool {
        switch self {
        case .tempo, .intervals, .race, .fartlek, .hills, .progression: true
        case .easy, .long, .recovery, .freeRun, .strides: false
        }
    }
}
enum SessionStatus: String, Codable, Sendable, CaseIterable { case planned, completed, missed, moved }
enum PRType: String, Codable, Sendable, CaseIterable {
    case fastest1k, fastest5k, fastest10k, longestRun, longestDuration
    // Half/marathon benchmark windows (2026-07-22, awards pass) — additive: stored as new raw
    // strings, so existing PersonalRecord rows are untouched.
    case fastestHalf, fastestMarathon
    // 50K benchmark window (2026-07-22) — the ultra finisher's own record, not a marathon split.
    case fastest50k
    case heaviestWeight, bestE1RM, repMax, bestSetVolume, bestSessionVolume
}
enum WorkoutPrivacy: String, Codable, Sendable, CaseIterable {
    case `private`, friends, `public`

    /// User-facing label for the visibility picker. "Friends" rhymes with the community wall's
    /// Friends | Global scope pill (2026-07-29) — one audience language across save and feed.
    var label: String {
        switch self {
        case .private: "Only me"
        case .friends: "Friends"
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
    /// E-bike is here deliberately (owner call 2026-08-05): picking "E-Bike Ride" means a
    /// STATIONARY e-bike, so it captures like the other stationary sports — glyph over the
    /// iridescent glow, never a map. Outdoor e-bikers pick Ride.
    var isTimed: Bool {
        switch self {
        case .tennis, .soccer, .basketball, .golf, .yoga, .pilates, .swimming, .rowing, .other,
             .eBikeRide: true
        default: false
        }
    }
    /// A GPS/map workout (run/ride/walk family) — carries a `gps` payload. The three capture modes
    /// are mutually exclusive: `isGPS`, `isStrengthStyle`, `isTimed`.
    var isGPS: Bool { !isStrengthStyle && !isTimed }

    /// Sports that carry a real distance/speed even without a route: every GPS sport, plus the
    /// stationary e-bike, whose console reports miles, speed and elevation like an outdoor ride —
    /// it just never maps. Gates distance ENTRY and display, never map rendering (that's `isGPS`).
    var tracksDistance: Bool { isGPS || self == .eBikeRide }

    /// Any bike. **Use this, never `== .ride`,** wherever a surface picks speed over pace or hides
    /// pace-shaped UI: cycling is FOUR cases, and an exact match against `.ride` silently left mountain,
    /// gravel and e-bike rides reporting a running pace in min/mi across the profile pager, the workout
    /// summary, splits, trends and share cards. Mirrors `discipline == .cycling` without importing the
    /// planning vocabulary into display code.
    var isCycling: Bool {
        switch self {
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide: true
        default: false
        }
    }

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
