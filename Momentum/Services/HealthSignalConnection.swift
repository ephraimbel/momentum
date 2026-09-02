/// The complete result of connecting Apple Health for signals.
///
/// Deliberately contains only permission state and current scalar signals. There is no workout,
/// workout summary, history collection, or persistence context in this boundary, so onboarding and
/// Settings cannot accidentally grow a second import path.
struct HealthSignalConnection: Sendable, Equatable {
    let workoutSharingAuthorized: Bool
    let bodyMassKg: Double?
    let restingHR: Int?
}

extension HealthServing {
    /// One shared connection path for onboarding and Settings. HealthKit does not disclose read
    /// authorization state, so the best-effort scalar reads run after the system sheet regardless of
    /// workout-write permission. Connecting never saves or returns a Momentum `Workout`.
    func connectForSignals() async -> HealthSignalConnection {
        let workoutSharingAuthorized = await requestAuthorization()
        let metrics = await currentBodyMetrics()
        return HealthSignalConnection(
            workoutSharingAuthorized: workoutSharingAuthorized,
            bodyMassKg: metrics.bodyMassKg,
            restingHR: metrics.restingHR)
    }
}
