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
    var reason: String = "health"
    var weightUnit: String = "kg"               // "kg" | "lb"
    var distanceUnit: String = "auto"           // "metric" | "imperial" | "auto"
    var maxHR: Int?
    var restingHR: Int?
    var birthYear: Int?
    var bodyMassKg: Double?
    var createdAt: Date = Date()

    // MARK: Social profile + privacy (opt-in; conservative defaults — see docs/SOCIAL-LAYER.md)
    var handle: String = ""                                  // @handle (lowercased, unique per user)
    var bio: String = ""
    var city: String = ""
    /// How precisely location may ever be shown publicly. Off by default.
    var locationGranularity: String = LocationGranularity.off.rawValue
    /// Default visibility applied to newly-finished workouts.
    var defaultWorkoutVisibility: String = WorkoutPrivacy.private.rawValue
    var appearOnMap: Bool = false                            // ephemeral fuzzed presence on the globe
    var publicRouteMaps: Bool = false                        // include (trimmed/fuzzed) routes on public posts
    var showExactNumbers: Bool = true                        // pace/weights on public posts
    var discoverable: Bool = false                           // appear in search / suggestions

    @Relationship(deleteRule: .cascade) var workouts: [Workout] = []
    @Relationship(deleteRule: .cascade) var plan: TrainingPlan?
    @Relationship(deleteRule: .cascade) var prs: [PersonalRecord] = []
    @Relationship(deleteRule: .cascade) var athlete: AthleteModel?

    init() {}
}
