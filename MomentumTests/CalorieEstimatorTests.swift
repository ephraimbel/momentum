import Testing
import Foundation
@testable import Momentum

/// Deterministic active-energy estimates (PRD §9). Distance-based for foot sports, MET×time for the
/// rest; body-mass aware with a sane default.
@MainActor
struct CalorieEstimatorTests {

    private func run(_ type: WorkoutType, distanceM: Double = 0, durationS: Double = 0) -> Workout {
        let w = Workout(); w.type = type; w.durationS = durationS
        if distanceM > 0 { let g = GPSDetail(); g.distanceM = distanceM; w.gps = g }
        return w
    }

    @Test func runningIsDistanceBasedAndMassScaled() {
        let tenK = run(.run, distanceM: 10_000, durationS: 3000)
        #expect(CalorieEstimator.kcal(for: tenK, bodyMassKg: 70) == 725)   // 1.036 × 70 × 10
        // Twice the mass ⇒ ~twice the energy.
        #expect(CalorieEstimator.kcal(for: tenK, bodyMassKg: 140) == 1450)
    }

    @Test func walkingIsAboutHalfOfRunningPerKm() {
        let walk = run(.walk, distanceM: 5_000, durationS: 3600)
        #expect(CalorieEstimator.kcal(for: walk, bodyMassKg: 70) == 186)   // 0.53 × 70 × 5
    }

    @Test func strengthIsMETTimesTime() {
        let lift = run(.strength, durationS: 3600)                          // 1 hour
        #expect(CalorieEstimator.kcal(for: lift, bodyMassKg: 80) == 400)   // 5 MET × 80 × 1
    }

    @Test func cyclingMETScalesWithSpeed() {
        // 20 km in 1 h = 20 km/h ⇒ 10 MET ⇒ 10 × 70 × 1 = 700.
        let ride = run(.ride, distanceM: 20_000, durationS: 3600)
        #expect(CalorieEstimator.kcal(for: ride, bodyMassKg: 70) == 700)
    }

    @Test func unknownMassUsesDefaultAndZeroWorkIsZero() {
        let tenK = run(.run, distanceM: 10_000, durationS: 3000)
        #expect(CalorieEstimator.kcal(for: tenK, bodyMassKg: nil)
                == CalorieEstimator.kcal(for: tenK, bodyMassKg: CalorieEstimator.defaultBodyMassKg))
        #expect(CalorieEstimator.kcal(for: run(.strength, durationS: 0), bodyMassKg: 70) == 0)
    }
}
