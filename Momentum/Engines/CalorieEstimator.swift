import Foundation

/// Active-energy estimate (kcal) for a completed workout — the deterministic engine behind the
/// calorie stat and the Apple Health energy sample (PRD §9: rules compute, AI never touches numbers).
///
/// Model (an estimate, like Apple's "Active Energy"):
///  • **Foot sports** are distance-based — the metabolic cost of running/walking a km is roughly
///    constant regardless of pace (~1.036 kcal·kg⁻¹·km⁻¹ running; about half that walking).
///  • **Everything else** is MET × bodyMass × hours (Compendium of Physical Activities), with cycling
///    MET derived from average speed.
/// Body-mass aware; falls back to a sane default when the athlete's weight is unknown.
enum CalorieEstimator {
    static let defaultBodyMassKg = 70.0

    static func kcal(for workout: Workout, bodyMassKg: Double?) -> Double {
        let mass = (bodyMassKg ?? defaultBodyMassKg) > 0 ? (bodyMassKg ?? defaultBodyMassKg) : defaultBodyMassKg
        let km = max(0, workout.gps?.distanceM ?? 0) / 1000
        let hours = max(0, workout.durationS) / 3600

        let raw: Double
        switch workout.type {
        case .run, .trailRun: raw = 1.036 * mass * km
        case .walk:           raw = 0.53 * mass * km
        case .hike:           raw = 0.62 * mass * km          // terrain + incline cost more than flat walking
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide:
            raw = cyclingMET(speedMS: km > 0 && hours > 0 ? km * 1000 / (hours * 3600) : 0) * mass * hours
        default:
            raw = met(for: workout.type) * mass * hours       // strength, timed, sports
        }
        return max(0, raw.rounded())
    }

    /// Fixed MET for non-cardio-distance activities (Compendium of Physical Activities).
    static func met(for type: WorkoutType) -> Double {
        switch type {
        case .strength:            5.0
        case .crossfit, .hiit:     8.0
        case .tennis:              7.3
        case .soccer:              7.0
        case .basketball:          6.5
        case .golf:                4.8
        case .yoga:                2.5
        case .pilates:             3.0
        case .swimming:            8.0   // moderate–vigorous freestyle
        case .rowing:              7.0   // moderate erg effort
        default:                   4.0
        }
    }

    /// Cycling MET from average speed (km/h bands, Compendium). 0 (no data) → leisurely default.
    static func cyclingMET(speedMS: Double) -> Double {
        let kmh = speedMS * 3.6
        switch kmh {
        case ..<0.1:    return 6.8
        case ..<16:     return 6.8
        case ..<19:     return 8.0
        case ..<22:     return 10.0
        case ..<25:     return 12.0
        default:        return 14.0
        }
    }
}
