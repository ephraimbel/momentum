import Foundation
import HealthKit
import Observation

/// On-wrist cardio capture (PRD §8.10) via `HKWorkoutSession` + `HKLiveWorkoutBuilder` — the watch
/// is the sensor. HealthKit's live data source feeds heart rate, active energy, and distance; the
/// session keeps running with the screen down (the `workout-processing` background mode). Real sensor
/// values need a physical Watch; on the simulator the session starts and the clock ticks while the
/// metrics stay at zero.
@MainActor
@Observable
final class WatchCardioModel: NSObject {
    let type: WorkoutType

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private(set) var heartRateBPM = 0
    private(set) var activeEnergyKcal = 0.0
    private(set) var distanceM = 0.0
    private(set) var running = false
    private(set) var paused = false
    private(set) var failed = false

    // DEBUG synthetic session for deterministic watch-sim verification (HealthKit can't run headless
    // on the sim, and sensor values need a real Watch). Mirrors the phone's `--ui-test-route`.
    private var demoStart: Date?
    private var demoTimer: Timer?
    private var demo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--watch-demo")
        #else
        false
        #endif
    }

    /// HK-managed elapsed time — freezes while paused. Read each tick from a `TimelineView`.
    var elapsed: TimeInterval {
        if let demoStart { return Date().timeIntervalSince(demoStart) }
        return builder?.elapsedTime ?? 0
    }

    init(type: WorkoutType) {
        self.type = type
        super.init()
    }

    /// Request authorization, then start the session + live collection.
    func start() async {
        if demo { startDemo(); return }
        guard HKHealthStore.isHealthDataAvailable() else { failed = true; return }
        let share: Set = [HKQuantityType.workoutType(), HKQuantityType(.activeEnergyBurned)]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling)
        ]
        do { try await healthStore.requestAuthorization(toShare: share, read: read) }
        catch { failed = true; return }

        let config = HKWorkoutConfiguration()
        config.activityType = Self.activityType(for: type)
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)
            running = true
        } catch { failed = true }
    }

    func togglePause() {
        if demo { paused.toggle(); return }
        guard let session else { return }
        paused ? session.resume() : session.pause()
    }

    #if DEBUG
    /// Run a synthetic ~3 m/s session so the live layout can be verified on the sim.
    private func startDemo() {
        demoStart = Date()
        running = true
        heartRateBPM = 148
        var tick = 0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused else { return }
                tick += 1
                self.distanceM += 3.0                       // ~3 m/s
                self.activeEnergyKcal += 0.18
                self.heartRateBPM = 148 + (tick % 7)        // gentle oscillation, no RNG
            }
        }
    }
    #endif

    /// End the session and finalize the workout into HealthKit.
    func end() async {
        if demo { demoTimer?.invalidate(); demoTimer = nil; running = false; return }
        session?.end()
        do {
            try await builder?.endCollection(at: Date())
            _ = try await builder?.finishWorkout()
        } catch { /* best-effort finalize; the session already ended */ }
        running = false
    }

    /// The discipline's planning bucket → HealthKit activity type.
    static func activityType(for type: WorkoutType) -> HKWorkoutActivityType {
        switch type.discipline {
        case .cycling: .cycling
        case .walking: .walking
        default: .running
        }
    }
}

// MARK: - HealthKit delegates (nonisolated; hop back to the main actor to publish)

extension WatchCardioModel: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ session: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor in
            running = (toState == .running)
            paused = (toState == .paused)
        }
    }

    nonisolated func workoutSession(_ session: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in failed = true }
    }
}

extension WatchCardioModel: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for sampleType in collectedTypes {
            guard let quantityType = sampleType as? HKQuantityType,
                  let stats = workoutBuilder.statistics(for: quantityType) else { continue }
            Task { @MainActor in apply(stats, for: quantityType) }
        }
    }

    @MainActor private func apply(_ stats: HKStatistics, for quantityType: HKQuantityType) {
        switch quantityType {
        case HKQuantityType(.heartRate):
            let bpm = HKUnit.count().unitDivided(by: .minute())
            if let v = stats.mostRecentQuantity()?.doubleValue(for: bpm) { heartRateBPM = Int(v.rounded()) }
        case HKQuantityType(.activeEnergyBurned):
            if let v = stats.sumQuantity()?.doubleValue(for: .kilocalorie()) { activeEnergyKcal = v }
        case HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling):
            if let v = stats.sumQuantity()?.doubleValue(for: .meter()) { distanceM = v }
        default:
            break
        }
    }
}
