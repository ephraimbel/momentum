import Foundation
import SwiftData

/// The user's profile and training inputs (PRD §8.7). Onboarding answers map here (§26).
@Model
final class UserProfile {
    var id: UUID = UUID()
    var displayName: String = ""
    var disciplines: [String] = ["running"]   // Discipline raw values
    var goal: Goal = Goal.generalFitness
    var experience: [String: String] = [:]     // discipline -> ExperienceLevel raw value
    var daysPerWeek: Int = 3
    var equipment: Equipment = Equipment.fullGym
    var sessionMinutes: Int = 45
    var raceDate: Date?
    /// Target race distance in meters (for "run a race" goals) — drives long-run progression + taper.
    var raceDistanceM: Double?
    /// Current running load, captured at onboarding — seeds the plan's starting volume so it meets the
    /// athlete where they are (not an experience-tier default). Both in meters (SI); nil until answered.
    var weeklyRunVolumeM: Double?
    var longestRunM: Double?
    /// Hybrid (run + lift) emphasis — biases the run/lift day split. `HybridPriority` raw value; nil →
    /// inferred from the goal.
    var hybridPriority: String?
    /// Target race finish time in seconds (race goals) — the athlete's aim, surfaced on the reveal and
    /// compared against the race predictor. nil → no explicit target.
    var goalFinishTimeS: Double?
    /// How hard the athlete chose to push (PlanIntensity raw value) — shapes the volume ramp + down-week
    /// cadence. nil → balanced.
    var planIntensity: String?
    /// Past injury areas from onboarding (InjuryArea raw values) — starts the plan protective and seeds
    /// the injury loop's watch list. Empty → none reported.
    var injuryHistory: [String] = []
    /// The currently-reported injury (ENDURANCE-FOCUS §8.2) — set by InjuryResponse.report, cleared by
    /// resume. Drives the "training around your…" state + the feeling-better affordance on Today.
    var activeInjuryArea: String?
    var activeInjurySeverity: String?
    var activeInjuryUntil: Date?
    /// Muscle groups the athlete wants to emphasize (MuscleGroup raw values) — biases strength volume.
    var muscleFocus: [String] = []
    /// Preferred training weekdays (Calendar weekday: 1 = Sunday … 7 = Saturday). Empty → auto-spread.
    var preferredDays: [Int] = []
    /// Tracked add-on activities the engine doesn't program (WorkoutType raws) — re-added on rebuild.
    var crossTraining: [String] = []
    /// Optional biological sex + height for load / HR / calorie tailoring.
    var sex: String?
    var heightCm: Double?
    var reason: String = "health"
    var weightUnit: String = "kg"               // "kg" | "lb"
    var distanceUnit: String = "auto"           // "metric" | "imperial" | "auto"
    var maxHR: Int?
    var restingHR: Int?
    var birthYear: Int?
    var bodyMassKg: Double?

    // FUEL goals (2026-07-16, docs/FUEL-FLOW.md) — the fueling adjuster's choice: how the daily
    // energy target is set. "fuel" (floors, the default) | "leaner" | "build" | "custom".
    // Custom numbers live here so the athlete's own targets survive re-computation.
    var fuelGoalKind: String?
    var fuelCustomKcal: Int?
    var fuelCustomProteinG: Int?
    var fuelCustomCarbsG: Int?
    var fuelCustomFatG: Int?
    var fuelCustomSodiumMg: Int?
    var createdAt: Date = Date()

    // MARK: Social profile + privacy (opt-in; conservative defaults — see docs/SOCIAL-LAYER.md)
    var handle: String = ""                                  // @handle (lowercased, unique per user)
    var bio: String = ""
    /// The athlete's chosen profile photo; nil → an initials avatar. Stored outside the row (blob).
    @Attribute(.externalStorage) var avatarData: Data?
    var city: String = ""
    /// How precisely location may ever be shown publicly. Off by default.
    var locationGranularity: String = LocationGranularity.off.rawValue
    /// Default visibility applied to newly-finished workouts.
    var defaultWorkoutVisibility: String = WorkoutPrivacy.private.rawValue
    var appearOnMap: Bool = false                            // ephemeral fuzzed presence on the globe
    /// Include (trimmed/fuzzed) routes on public posts. Defaults ON since 2026-08-06 (Strava's
    /// default; the server still trims start/end): it shipped defaulting false with NO surface
    /// anywhere to turn it on, so every own GPS post rendered the sport glyph instead of its
    /// route, forever. `SocialPrivacy.migrateRouteMapsDefault` flips profiles stored under the
    /// old default once.
    var publicRouteMaps: Bool = true
    var showExactNumbers: Bool = true                        // pace/weights on public posts
    var discoverable: Bool = false                           // appear in search / suggestions

    @Relationship(deleteRule: .cascade) var workouts: [Workout] = []
    @Relationship(deleteRule: .cascade) var plan: TrainingPlan?
    @Relationship(deleteRule: .cascade) var prs: [PersonalRecord] = []
    @Relationship(deleteRule: .cascade) var athlete: AthleteModel?

    init() {}
}
