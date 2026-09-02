import Foundation
import SwiftData
import Testing
@testable import Momentum

@MainActor
struct HealthSignalConnectionTests {
    @Test func connectingReadsSignalsWithoutSavingOrCreatingAWorkout() async throws {
        let persistence = PersistenceController.inMemory()
        let context = persistence.container.mainContext
        let before = try context.fetchCount(FetchDescriptor<Workout>())
        let health = HealthSpy()

        let connection = await health.connectForSignals()

        #expect(connection == HealthSignalConnection(
            workoutSharingAuthorized: true,
            bodyMassKg: 63.5,
            restingHR: 49))
        #expect(health.calls == [.authorization, .bodyMetrics])
        #expect(try context.fetchCount(FetchDescriptor<Workout>()) == before)
    }

    @MainActor
    private final class HealthSpy: HealthServing {
        enum Call: Equatable { case authorization, bodyMetrics, save }
        var calls: [Call] = []
        var isAuthorized = true

        func requestAuthorization() async -> Bool {
            calls.append(.authorization)
            return true
        }

        func currentBodyMetrics() async -> (bodyMassKg: Double?, restingHR: Int?) {
            calls.append(.bodyMetrics)
            return (63.5, 49)
        }

        func save(_ workout: Workout, includeEnergy: Bool) async { calls.append(.save) }
        func measuredActiveEnergy(start: Date, end: Date) async -> Double? { nil }
        func recoverySignals() async -> RecoverySignals { .empty }
        func measuredVO2Max() async -> Double? { nil }
        func heartRateSeries(start: Date, end: Date) async -> [(date: Date, bpm: Double)] { [] }
        func dailySteps(daysBack: Int) async -> [(day: Date, steps: Double)] { [] }
    }
}
