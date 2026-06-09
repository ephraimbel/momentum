import Foundation

// Unified domain enums (PRD §8.7). Stored as raw strings for SwiftData/Supabase portability.

enum WorkoutType: String, Codable, Sendable, CaseIterable { case run, ride, walk, hike, strength }
enum Discipline: String, Codable, Sendable, CaseIterable { case running, cycling, walking, strength }
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
    case `private`, friends, `public` // friends/public reserved for deferred social
}

extension WorkoutType: Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .run: "Run"; case .ride: "Ride"; case .walk: "Walk"; case .hike: "Hike"; case .strength: "Strength"
        }
    }

    var systemImage: String {
        switch self {
        case .run: "figure.run"
        case .ride: "bicycle"
        case .walk: "figure.walk"
        case .hike: "figure.hiking"
        case .strength: "dumbbell.fill"
        }
    }

    /// Each `Workout` carries exactly one of `gps`/`strength`, determined by `type`.
    var isGPS: Bool { self != .strength }
    /// `hike` maps to the walking `Discipline` for planning/analytics (§8.7 notes).
    var discipline: Discipline {
        switch self {
        case .run: .running
        case .ride: .cycling
        case .walk, .hike: .walking
        case .strength: .strength
        }
    }
}
