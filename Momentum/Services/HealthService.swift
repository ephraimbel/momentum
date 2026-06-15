import Foundation
import HealthKit

/// Writes completed workouts to Apple Health (PRD §8.6). Best-effort and non-blocking — a Health
/// failure never affects the in-app save — and de-duplicated, so a workout reaches Health at most
/// once. Authorization is opt-in (Settings → Apple Health); until then every call is a silent no-op.
@MainActor
final class HealthService: HealthServing {
    private let store = HKHealthStore()
    private static let savedKey = "com.momentum.health.savedWorkoutIDs"

    /// Types we write. Reads (HR, resting HR, body mass, steps) are requested so a later slice can
    /// personalize from them; the write set is what gates `isAuthorized`.
    private static let shareTypes: Set<HKSampleType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.distanceCycling),
    ]
    private static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.bodyMass),
        HKQuantityType(.stepCount),
    ]

    /// True once the user has granted permission to share workouts. (HealthKit hides read status by
    /// design, so write authorization is the honest "connected" signal.)
    var isAuthorized: Bool {
        HKHealthStore.isHealthDataAvailable()
            && store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do { try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes) }
        catch { return false }
        return isAuthorized
    }

    func save(_ workout: Workout) async {
        guard isAuthorized, !isAlreadySaved(workout.id) else { return }

        let start = workout.startedAt
        let duration = workout.durationS > 0 ? workout.durationS : workout.elapsedS
        let end = start.addingTimeInterval(max(1, duration))

        let config = HKWorkoutConfiguration()
        config.activityType = Self.activityType(for: workout.type)
        config.locationType = workout.type.isGPS ? .outdoor : .indoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)

            var samples: [HKSample] = []
            if let kcal = workout.calories, kcal > 0 {
                samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal), start: start, end: end))
            }
            if let distance = workout.gps?.distanceM, distance > 0 {
                let type = workout.type.discipline == .cycling
                    ? HKQuantityType(.distanceCycling) : HKQuantityType(.distanceWalkingRunning)
                samples.append(HKQuantitySample(type: type,
                    quantity: HKQuantity(unit: .meter(), doubleValue: distance), start: start, end: end))
            }
            if !samples.isEmpty { try await builder.addSamples(samples) }

            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            markSaved(workout.id)
        } catch {
            // Best-effort: never block the user. A future save will retry (id stays un-marked).
        }
    }

    /// Read the athlete's most recent body mass + resting HR from Health, to personalize estimates
    /// (calories) and recovery signals (PRD §8.6). Returns `nil`s when unavailable/unauthorized.
    func importedBodyMetrics() async -> (bodyMassKg: Double?, restingHR: Int?) {
        guard HKHealthStore.isHealthDataAvailable() else { return (nil, nil) }
        async let mass = latest(.bodyMass, unit: .gramUnit(with: .kilo))
        async let rhr = latest(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        return (await mass, (await rhr).map { Int($0.rounded()) })
    }

    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        await withCheckedContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            let query = HKSampleQuery(sampleType: HKQuantityType(id), predicate: nil,
                                      limit: 1, sortDescriptors: sort) { _, samples, _ in
                continuation.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Pure mapping (testable): our discipline-rich `WorkoutType` → the nearest HealthKit activity.
    static func activityType(for type: WorkoutType) -> HKWorkoutActivityType {
        switch type {
        case .run, .trailRun: .running
        case .walk: .walking
        case .hike: .hiking
        case .ride, .mountainBikeRide, .gravelRide, .eBikeRide: .cycling
        case .strength: .traditionalStrengthTraining
        case .crossfit: .crossTraining
        case .hiit: .highIntensityIntervalTraining
        case .tennis: .tennis
        case .soccer: .soccer
        case .basketball: .basketball
        case .golf: .golf
        case .yoga: .yoga
        case .pilates: .pilates
        case .other: .other
        }
    }

    // MARK: Dedupe (UserDefaults set of saved workout UUIDs)

    private func isAlreadySaved(_ id: UUID) -> Bool { savedIDs().contains(id.uuidString) }
    private func markSaved(_ id: UUID) {
        var ids = savedIDs(); ids.insert(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: Self.savedKey)
    }
    private func savedIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.savedKey) ?? [])
    }
}
