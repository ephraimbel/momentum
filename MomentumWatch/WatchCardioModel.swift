import Foundation
import CoreLocation
import HealthKit
import Observation
import WatchKit

/// On-wrist cardio capture (PRD §8.10) via `HKWorkoutSession` + `HKLiveWorkoutBuilder` — the watch
/// is the sensor. HealthKit's live data source feeds heart rate, active energy, and distance; the
/// session keeps running with the screen down (the `workout-processing` background mode). A
/// CoreLocation stream (same 25 m accuracy gate as the phone, PRD §20) records the route for the
/// live map page and the summary trace. A 1 Hz metronome derives what Garmin/COROS derive on the
/// wrist: time-in-zone (Karvonen `HRZones`, Tanaka max-HR from Health date of birth) and auto-lap
/// splits with a haptic per lap. Real sensor values need a physical Watch; on the simulator the
/// session starts and the clock ticks while the metrics stay at zero.
@MainActor
@Observable
final class WatchCardioModel: NSObject {
    let type: WorkoutType

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// Persists the GPS trail into HealthKit as an `HKWorkoutRoute` attached to the workout —
    /// this is what lets the phone draw the run on its (Mapbox) maps after import.
    private var routeBuilder: HKWorkoutRouteBuilder?
    private let locationManager = CLLocationManager()
    private var metronome: Timer?

    private(set) var heartRateBPM = 0
    private(set) var activeEnergyKcal = 0.0
    private(set) var distanceM = 0.0
    private(set) var running = false
    private(set) var paused = false
    private(set) var failed = false
    /// Location permission denied/restricted — the map page says so instead of "Finding GPS…".
    private(set) var locationDenied = false
    /// Latched by `end()`. Makes teardown idempotent and gates every late-arriving write
    /// (metronome tick, location fix, control tap) so nothing mutates a closed session.
    private(set) var hasEnded = false
    /// Set once at `end()` so the summary's Time never creeps after the session closes.
    private var frozenElapsed: TimeInterval?
    /// Wall-clock anchor for the metronome: accrual uses real elapsed deltas, not tick counts,
    /// so coalesced/deferred timer fires (screen off) don't under-count time-in-zone.
    private var lastTickAt: Date?

    // Route (gated CoreLocation fixes; the map page and summary trace read this).
    private(set) var route: [CLLocationCoordinate2D] = []

    // Zone model — resolved at start (Tanaka 208 − 0.7·age from Health DOB, else 190).
    private(set) var zones: [HRZones.Zone] = []
    /// Seconds accrued in each zone (index 0 = Z1). Driven by the 1 Hz metronome.
    private(set) var timeInZone: [TimeInterval] = [0, 0, 0, 0, 0]

    // Splits — auto-lap every km (mi in imperial regions), plus the manual Lap button.
    /// Completed lap durations, oldest first. Each is seconds for one lap.
    private(set) var splits: [TimeInterval] = []
    private(set) var lastSplitS: TimeInterval = 0
    let splitLengthM: Double = DistanceUnit.auto.resolved() == .imperial ? Formatters.metersPerMile : 1000
    private var lapStartElapsed: TimeInterval = 0
    private var lapStartDistance: Double = 0

    // HR aggregates for the summary.
    private var hrSum = 0.0
    private var hrTicks = 0.0
    private(set) var maxObservedHR = 0
    var avgHR: Int { hrTicks > 0 ? Int((hrSum / hrTicks).rounded()) : 0 }

    // DEBUG synthetic session for deterministic watch-sim verification (HealthKit can't run headless
    // on the sim, and sensor values need a real Watch). Mirrors the phone's `--ui-test-route`.
    private var demoStart: Date?
    private var demoTick = 0
    private var demoPausedAccum: TimeInterval = 0
    private var demoPauseBegan: Date?
    private var demo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--watch-demo")
        #else
        false
        #endif
    }

    /// HK-managed elapsed time — freezes while paused. Read each tick from a `TimelineView`.
    var elapsed: TimeInterval {
        if let frozenElapsed { return frozenElapsed }
        if let demoStart {
            let pausedNow = demoPauseBegan.map { Date().timeIntervalSince($0) } ?? 0
            return Date().timeIntervalSince(demoStart) - demoPausedAccum - pausedNow
        }
        return builder?.elapsedTime ?? 0
    }

    /// 1-based zone for the current heart rate (0 when no HR yet).
    var currentZone: Int {
        guard heartRateBPM > 0, !zones.isEmpty else { return 0 }
        if heartRateBPM < zones[0].bpm.lowerBound { return 1 }
        return zones.last(where: { heartRateBPM >= $0.bpm.lowerBound })?.index ?? 1
    }

    /// 0…1 position across the whole five-zone span, for the gauge pointer.
    var zoneFraction: Double {
        guard let lo = zones.first?.bpm.lowerBound, let hi = zones.last?.bpm.upperBound,
              hi > lo, heartRateBPM > 0 else { return 0 }
        return min(1, max(0, Double(heartRateBPM - lo) / Double(hi - lo)))
    }

    init(type: WorkoutType) {
        self.type = type
        super.init()
    }

    /// Request authorization, then start the session + live collection + the route stream.
    func start() async {
        zones = HRZones.zones(maxHR: 190) ?? []          // placeholder until DOB resolves
        if demo { startDemo(); return }
        guard HKHealthStore.isHealthDataAvailable() else { failed = true; return }
        let share: Set = [HKQuantityType.workoutType(), HKQuantityType(.activeEnergyBurned),
                          HKSeriesType.workoutRoute()]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling),
            HKCharacteristicType(.dateOfBirth)
        ]
        do { try await healthStore.requestAuthorization(toShare: share, read: read) }
        catch { failed = true; return }
        // The auth sheet can sit open indefinitely — if the view died meanwhile (end() ran),
        // don't start an orphan session nothing can ever stop.
        guard !hasEnded else { return }
        resolveZones()

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
            self.routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)

            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)
            running = true
        } catch { failed = true; return }

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = type.discipline == .cycling ? .otherNavigation : .fitness
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        startMetronome()
    }

    /// Personalize the five zones from Health's date of birth (Tanaka max HR); keep 190 otherwise.
    private func resolveZones() {
        guard let dob = try? healthStore.dateOfBirthComponents(),
              let birth = Calendar.current.date(from: dob) else { return }
        let age = Calendar.current.dateComponents([.year], from: birth, to: Date()).year ?? 0
        guard age > 8, age < 110 else { return }
        let maxHR = Int((208.0 - 0.7 * Double(age)).rounded())
        if let z = HRZones.zones(maxHR: maxHR) { zones = z }
    }

    func togglePause() {
        guard !hasEnded else { return }
        if demo {
            paused.toggle()
            if paused { demoPauseBegan = Date() }
            else if let began = demoPauseBegan {
                demoPausedAccum += Date().timeIntervalSince(began)
                demoPauseBegan = nil
            }
            return
        }
        guard let session else { return }
        paused ? session.resume() : session.pause()
    }

    /// Manual lap (Garmin-style): close the current lap now and restart the counter.
    func lap() {
        guard running, !hasEnded else { return }
        recordSplit()
        WKInterfaceDevice.current().play(.directionUp)
    }

    // MARK: 1 Hz metronome — zone accrual + auto-lap (and, in demo, synthetic sensors)

    private func startMetronome() {
        lastTickAt = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.2
        metronome = timer
    }

    private func tick() {
        guard running, !hasEnded else { lastTickAt = Date(); return }
        if demo { demoAdvance() }
        guard !paused else { lastTickAt = Date(); return }
        // Accrue by real elapsed time, not per fire: with the screen off the system coalesces
        // run-loop timers, and counting fires would silently shrink time-in-zone on long runs.
        let now = Date()
        let delta = min(max(now.timeIntervalSince(lastTickAt ?? now), 0), 120)
        lastTickAt = now
        if heartRateBPM > 0, delta > 0 {
            hrSum += Double(heartRateBPM) * delta
            hrTicks += delta
            maxObservedHR = max(maxObservedHR, heartRateBPM)
            let z = currentZone
            if z >= 1 { timeInZone[z - 1] += delta }
        }
        if distanceM - lapStartDistance >= splitLengthM {
            recordSplit()
            WKInterfaceDevice.current().play(.notification)
        }
    }

    private func recordSplit() {
        let lapS = elapsed - lapStartElapsed
        guard lapS > 1 else { return }
        splits.append(lapS)
        lastSplitS = lapS
        lapStartElapsed = elapsed
        lapStartDistance = distanceM
    }

    #if DEBUG
    /// Run a synthetic session so every live page can be verified on the sim: ~3.2 m/s along a
    /// parametric park loop, HR sweeping Z1→Z4. Deterministic — no RNG.
    private func startDemo() {
        demoStart = Date()
        running = true
        heartRateBPM = 128
        startMetronome()
    }

    private func demoAdvance() {
        guard !paused else { return }
        demoTick += 1
        distanceM += 3.2
        activeEnergyKcal += 0.19
        heartRateBPM = 132 + Int((34 * sin(Double(demoTick) / 60)).rounded())
        route.append(Self.demoCoordinate(tick: demoTick))
    }

    /// A gently wobbled loop around a park — reads as a real run on the map and the trace.
    private static func demoCoordinate(tick: Int) -> CLLocationCoordinate2D {
        let theta = Double(tick) / 480 * 2 * .pi
        let lat = 37.7694 + 0.0016 * sin(theta) + 0.00018 * sin(3.1 * theta)
        let lon = -122.4762 + 0.0022 * cos(theta) + 0.00021 * sin(2.3 * theta)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Fabricate a finished ~27-min 5K so the summary screen can be verified deterministically
    /// on the sim (`--watch-demo --watch-page=summary`).
    func seedDemoSummary() {
        zones = HRZones.zones(maxHR: 190) ?? []
        frozenElapsed = 1622
        distanceM = 5 * splitLengthM + 243   // 5 completed laps + change, coherent in any locale
        activeEnergyKcal = 388
        heartRateBPM = 152
        hrSum = 148 * 1500; hrTicks = 1500
        maxObservedHR = 174
        splits = [318, 309, 304, 312, 299]
        lastSplitS = 299
        timeInZone = [120, 540, 610, 260, 92]
        route = (0...480).map { Self.demoCoordinate(tick: $0) }
        running = false
    }
    #endif

    /// End the session and finalize the workout into HealthKit. Idempotent — every exit path
    /// (End button, failure Close, view teardown) funnels here and later calls are no-ops.
    func end() async {
        guard !hasEnded else { return }
        hasEnded = true
        metronome?.invalidate(); metronome = nil
        frozenElapsed = elapsed
        if demo { running = false; return }
        locationManager.stopUpdatingLocation()
        session?.end()
        do {
            try await builder?.endCollection(at: Date())
            let workout = try await builder?.finishWorkout()
            if let workout, !route.isEmpty {
                try await routeBuilder?.finishRoute(with: workout, metadata: nil)
            }
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

// MARK: - Route capture (same accept gate as the phone: accuracy ∈ (0, 25 m], PRD §20)

extension WatchCardioModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let accepted = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 25 }
        guard !accepted.isEmpty else { return }
        Task { @MainActor in
            guard !paused, !hasEnded else { return }
            // Full-fidelity trail into HealthKit (the phone draws this after import)…
            try? await routeBuilder?.insertRouteData(accepted)
            // …decimated coordinates (≥ 3 m apart) for the on-wrist map, so hours stay light.
            for coord in accepted.map(\.coordinate) {
                if let last = route.last {
                    let d = CLLocation(latitude: last.latitude, longitude: last.longitude)
                        .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
                    guard d >= 3 else { continue }
                }
                route.append(coord)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Route is an enhancement — the workout keeps recording without it.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            locationDenied = (status == .denied || status == .restricted)
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
