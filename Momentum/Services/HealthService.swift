import Foundation
import HealthKit
import SwiftData

/// Writes completed workouts to Apple Health (PRD §8.6). Best-effort and non-blocking — a Health
/// failure never affects the in-app save — and de-duplicated, so a workout reaches Health at most
/// once. Authorization is opt-in (Settings → Apple Health); until then every call is a silent no-op.
@MainActor
final class HealthService: HealthServing {
    private let store = HKHealthStore()
    private static let savedKey = "com.momentum.health.savedWorkoutIDs"
    private static let importedKey = "com.momentum.health.importedWorkoutIDs"

    /// Types we write. Reads (HR, resting HR, body mass, steps) are requested so a later slice can
    /// personalize from them; the write set is what gates `isAuthorized`.
    private static let shareTypes: Set<HKSampleType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.distanceCycling),
    ]
    private static let readTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),               // import workouts from other apps/devices (Garmin, Watch)
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN), // recovery: HRV (Watch / Garmin / Oura → Health)
        HKCategoryType(.sleepAnalysis),            // recovery: last night's sleep
        HKQuantityType(.vo2Max),                   // fitness: device-measured VO₂max (Watch / Garmin)
        HKQuantityType(.bodyMass),
        HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned),       // workout calorie totals
        HKQuantityType(.distanceWalkingRunning),   // workout distance totals
        HKQuantityType(.distanceCycling),
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
            // Stamp our own writes so the importer can skip them (an echo of a workout already in our
            // store) while still importing foreign ones (Garmin, Apple Watch) that lack this marker.
            try await builder.addMetadata([HKMetadataKeyExternalUUID: workout.id.uuidString])

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

    /// Read the recovery signals wearables mirror into Health — HRV (SDNN), resting HR, and last
    /// night's sleep — each with a ~30-day baseline so the value reads against the athlete's own norm
    /// (PRD §4.8, §8.6). Best-effort; every field is `nil` when unavailable/unauthorized.
    func recoverySignals() async -> RecoverySignals {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--health-recovery-demo") { return .demo }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return .empty }
        let ms = HKUnit.secondUnit(with: .milli)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        async let hrv = latest(.heartRateVariabilitySDNN, unit: ms)
        async let hrvBase = average(.heartRateVariabilitySDNN, unit: ms, days: 30)
        async let rhr = latest(.restingHeartRate, unit: bpm)
        async let rhrBase = average(.restingHeartRate, unit: bpm, days: 30)
        async let sleep = sleepHoursLastNight()
        return RecoverySignals(
            hrvMs: await hrv, hrvBaselineMs: await hrvBase,
            restingHR: (await rhr).map { Int($0.rounded()) }, restingHRBaseline: await rhrBase,
            sleepHours: await sleep)
    }

    /// The device-measured VO₂max from Apple Health (Apple Watch outdoor runs, Garmin, etc.) — a real
    /// cardiorespiratory measurement we prefer over our pace-derived estimate when present. `nil` if none.
    func measuredVO2Max() async -> Double? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--health-recovery-demo") { return 42.4 }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        return await latest(.vo2Max, unit: HKUnit(from: "ml/kg*min"))
    }

    /// Estimate the athlete's current running baseline from their recent Health run history — the
    /// onboarding "it already understands me" import (ENDURANCE-FOCUS §4). Reads runs from ANY source
    /// (Watch, Garmin, Strava re-syncs…), maps them to samples, and hands off to the pure estimator.
    func runningBaseline() async -> BaselineEstimator.RunningBaseline? {
        #if DEBUG
        // Sim has no Health data — a believable demo baseline so the import card's success state is
        // verifiable end-to-end (26:40 5K-equivalent, ~21 km/wk, 10K long run).
        if ProcessInfo.processInfo.arguments.contains("--health-baseline-demo") {
            return .init(p5kSPerKm: 320, weeklyVolumeM: 21_000, longestRunM: 10_000,
                         runsPerWeek: 3.1, runCount: 25, confidence: .high)
        }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let cutoff = Date().addingTimeInterval(-Double(BaselineEstimator.windowDays) * 86_400)
        let runs = await fetchWorkouts(since: cutoff)
            .filter { $0.workoutActivityType == .running }
            .compactMap { hk -> BaselineEstimator.RunSample? in
                let meters = hk.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                    .sumQuantity()?.doubleValue(for: .meter()) ?? 0
                guard meters > 0 else { return nil }
                return .init(date: hk.startDate, distanceM: meters, durationS: hk.duration)
            }
        return BaselineEstimator.estimate(from: runs)
    }

    // MARK: Import (Apple Watch / Garmin via Apple Health → our store)

    /// Pull workouts recorded by **other** sources (Apple Watch, Garmin via Garmin Connect, Strava,
    /// etc.) out of Apple Health and into our local store (PRD §8.6). The realistic "connect to
    /// Garmin" path — Garmin Connect mirrors activities into Health, and we ingest them here.
    ///
    /// - Our own writes are skipped (same source bundle *and* our `externalUUID` marker), so a saved
    ///   momentum workout never re-imports as a duplicate of itself.
    /// - Every HealthKit workout imports at most once (UUID dedupe, persisted).
    /// - Imported workouts are marked already-saved so we never echo them straight back to Health.
    ///
    /// Best-effort and non-blocking; returns the number newly imported.
    @discardableResult
    func importExternalWorkouts(into context: ModelContext, since: Date? = nil) async -> Int {
        guard HKHealthStore.isHealthDataAvailable() else { return 0 }
        let cutoff = since ?? Calendar.current.date(byAdding: .year, value: -1, to: Date())
        let hkWorkouts = await fetchWorkouts(since: cutoff)
        guard !hkWorkouts.isEmpty else { return 0 }

        let ownBundle = Bundle.main.bundleIdentifier
        var imported = savedSet(Self.importedKey)
        var saved = savedSet(Self.savedKey)
        var count = 0

        // Overlap dedupe: the same physical run often exists twice — tracked here AND logged
        // independently by a Watch/Garmin whose copy syncs into Health under its own source bundle
        // (so the same-bundle echo check can't catch it). Importing that copy double-counts weekly
        // volume, ACWR, and every stat. Spans include this loop's own imports so two external
        // copies of one run don't both land either.
        var existingSpans: [(start: Date, end: Date)] =
            ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
                .map { ($0.startedAt, $0.startedAt.addingTimeInterval(max($0.elapsedS, $0.durationS))) }
        let plan = ((try? context.fetch(FetchDescriptor<UserProfile>())) ?? []).first?.plan

        for hk in hkWorkouts {
            guard Self.shouldImport(sourceBundle: hk.sourceRevision.source.bundleIdentifier,
                                    ownBundle: ownBundle, metadata: hk.metadata ?? [:],
                                    alreadyImported: imported, uuid: hk.uuid.uuidString)
            else { continue }
            guard !Self.overlapsExisting(start: hk.startDate, end: hk.endDate, spans: existingSpans) else {
                imported.insert(hk.uuid.uuidString)   // remember the verdict — don't re-evaluate every sync
                continue
            }

            let type = Self.workoutType(for: hk.workoutActivityType)
            let calories = hk.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
            var distanceM = 0.0
            if type.isGPS {
                let distID: HKQuantityTypeIdentifier = type.discipline == .cycling
                    ? .distanceCycling : .distanceWalkingRunning
                distanceM = hk.statistics(for: HKQuantityType(distID))?.sumQuantity()?.doubleValue(for: .meter()) ?? 0
            }
            let avgHR = await averageHR(start: hk.startDate, end: hk.endDate)

            let workout = Self.assembleImport(
                type: type, start: hk.startDate, duration: hk.duration,
                elapsed: hk.endDate.timeIntervalSince(hk.startDate),
                calories: calories, distanceM: distanceM, avgHR: avgHR)
            context.insert(workout)
            existingSpans.append((hk.startDate, hk.endDate))
            imported.insert(hk.uuid.uuidString)
            saved.insert(workout.id.uuidString)
            // A Garmin/Watch long run fulfills the plan exactly like a tracked one — credit it, so
            // the athlete who recorded on their watch doesn't find today's session still "open".
            PlanCoaching.creditWorkout(workout, to: plan, in: context)
            count += 1
        }

        if count > 0 {
            UserDefaults.standard.set(Array(imported), forKey: Self.importedKey)
            UserDefaults.standard.set(Array(saved), forKey: Self.savedKey)
            try? context.save()
        }
        return count
    }

    /// Pure import filter (testable): skip our own echoes and anything already imported.
    static func shouldImport(sourceBundle: String?, ownBundle: String?, metadata: [String: Any],
                             alreadyImported: Set<String>, uuid: String) -> Bool {
        // Our own write: same app bundle *and* carries the externalUUID we stamp on save().
        if sourceBundle == ownBundle, metadata[HKMetadataKeyExternalUUID] != nil { return false }
        return !alreadyImported.contains(uuid)
    }

    /// Pure overlap check (testable): an incoming Health workout that shares more than half of the
    /// shorter recording with something we already have is the same physical session, not a new one.
    /// Straddling midnight is irrelevant here — this is pure interval math.
    nonisolated static func overlapsExisting(start: Date, end: Date,
                                             spans: [(start: Date, end: Date)]) -> Bool {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return false }
        for span in spans {
            let overlap = min(end, span.end).timeIntervalSince(max(start, span.start))
            guard overlap > 0 else { continue }
            let shorter = min(duration, span.end.timeIntervalSince(span.start))
            if shorter > 0, overlap / shorter > 0.5 { return true }
        }
        return false
    }

    /// Pure assembly (testable): build a `Workout` from extracted HealthKit values. GPS types get a
    /// `gps` payload with derived pace (run/walk) or speed (ride); strength/timed stay payload-free.
    static func assembleImport(type: WorkoutType, start: Date, duration: Double, elapsed: Double,
                               calories: Double?, distanceM: Double, avgHR: Int?) -> Workout {
        let w = Workout()
        w.type = type
        w.startedAt = start
        w.durationS = duration
        w.elapsedS = max(elapsed, duration)
        w.calories = (calories ?? 0) > 0 ? calories : nil
        if type.isGPS {
            let gps = GPSDetail()
            gps.distanceM = distanceM
            if distanceM > 0, duration > 0 {
                if type.discipline == .cycling { gps.avgSpeedMS = distanceM / duration }
                else { gps.avgPaceSPerKm = duration / (distanceM / 1000) }
            }
            gps.avgHR = avgHR
            w.gps = gps
        }
        return w
    }

    /// Pure mapping (testable): HealthKit activity → our discipline-rich `WorkoutType`. Inverse of
    /// `activityType(for:)` for the types we capture; everything else falls back to `.other`.
    static func workoutType(for activity: HKWorkoutActivityType) -> WorkoutType {
        switch activity {
        case .running: .run
        case .walking: .walk
        case .hiking: .hike
        case .cycling: .ride
        case .traditionalStrengthTraining, .functionalStrengthTraining: .strength
        case .crossTraining: .crossfit
        case .highIntensityIntervalTraining: .hiit
        case .tennis: .tennis
        case .soccer: .soccer
        case .basketball: .basketball
        case .golf: .golf
        case .yoga: .yoga
        case .pilates: .pilates
        case .swimming: .swimming
        case .rowing: .rowing
        default: .other
        }
    }

    private func fetchWorkouts(since: Date?) async -> [HKWorkout] {
        await withCheckedContinuation { continuation in
            let predicate = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil) }
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    /// The full heart-rate series for a workout window (Watch/Garmin runs carry one in Health) — feeds
    /// the time-in-zones card. Empty when unauthorized or the workout has no HR data.
    func heartRateSeries(start: Date, end: Date) async -> [(date: Date, bpm: Double)] {
        #if DEBUG
        // Sim has no Health data — a believable interval-session series so the zones card is verifiable
        // (warmup Z2 → 4 hard reps touching Z4/Z5 with Z2 floats → cooldown Z1/Z2).
        if ProcessInfo.processInfo.arguments.contains("--zones-demo") {
            var out: [(Date, Double)] = []
            let duration = min(end.timeIntervalSince(start), 40 * 60)
            var t: TimeInterval = 0
            while t < duration {
                let phase = t / duration
                let bpm: Double
                switch phase {
                case ..<0.15: bpm = 125 + phase * 100          // warmup drift up
                case ..<0.85:
                    let rep = sin((phase - 0.15) / 0.7 * .pi * 4)   // 4 work/float waves
                    bpm = rep > 0 ? 168 + rep * 12 : 142
                default: bpm = 130 - (phase - 0.85) * 80       // cooldown
                }
                out.append((start.addingTimeInterval(t), bpm))
                t += 5
            }
            return out
        }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: HKQuantityType(.heartRate), predicate: predicate,
                                      limit: 4_000, sortDescriptors: [sort]) { _, samples, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let out = (samples as? [HKQuantitySample])?.map {
                    (date: $0.startDate, bpm: $0.quantity.doubleValue(for: unit))
                } ?? []
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    private func averageHR(start: Date, end: Date) async -> Int? {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let query = HKStatisticsQuery(quantityType: HKQuantityType(.heartRate),
                                          quantitySamplePredicate: predicate,
                                          options: .discreteAverage) { _, stats, _ in
                let bpm = stats?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                continuation.resume(returning: bpm.map { Int($0.rounded()) })
            }
            store.execute(query)
        }
    }

    private func savedSet(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
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

    /// Discrete average of a quantity over the last `days` — the athlete's personal baseline for a
    /// recovery signal (HRV, resting HR). `nil` when there are no samples in the window.
    private func average(_ id: HKQuantityTypeIdentifier, unit: HKUnit, days: Int) async -> Double? {
        await withCheckedContinuation { continuation in
            let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())
            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
            let query = HKStatisticsQuery(quantityType: HKQuantityType(id),
                                          quantitySamplePredicate: predicate,
                                          options: .discreteAverage) { _, stats, _ in
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Hours of actual sleep in the most recent night — sums `asleep*` category samples from the last
    /// 18 hours (long enough to catch last night, short enough to exclude the night before). Naps fold
    /// in; "in bed" (awake) time is excluded. `nil` when there's no sleep recorded.
    private func sleepHoursLastNight() async -> Double? {
        await withCheckedContinuation { continuation in
            let start = Calendar.current.date(byAdding: .hour, value: -18, to: Date())
            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let asleep: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                ]
                let seconds = (samples as? [HKCategorySample] ?? [])
                    .filter { asleep.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                continuation.resume(returning: seconds > 0 ? seconds / 3600 : nil)
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
        case .swimming: .swimming
        case .rowing: .rowing
        case .other: .other
        }
    }

    #if DEBUG
    /// Sim-only: write a few synthetic workouts to Health (run / ride / strength) as if recorded by
    /// another device, so the import path can be exercised without a physical Garmin. Deliberately
    /// omits our `externalUUID` marker, so the importer treats them as foreign. No-op without auth.
    func seedSyntheticHealthWorkouts() async {
        guard isAuthorized else { return }
        let now = Date()
        await seedOne(.running, start: now.addingTimeInterval(-3600), duration: 1800, kcal: 320, distanceM: 5000)
        await seedOne(.cycling, start: now.addingTimeInterval(-7200), duration: 2400, kcal: 410, distanceM: 16000)
        await seedOne(.traditionalStrengthTraining, start: now.addingTimeInterval(-10800), duration: 2700, kcal: 260, distanceM: 0)
    }

    private func seedOne(_ activity: HKWorkoutActivityType, start: Date, duration: Double,
                         kcal: Double, distanceM: Double) async {
        let end = start.addingTimeInterval(duration)
        let config = HKWorkoutConfiguration(); config.activityType = activity
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)
            var samples: [HKSample] = [HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal), start: start, end: end)]
            if distanceM > 0 {
                let dt = activity == .cycling ? HKQuantityType(.distanceCycling) : HKQuantityType(.distanceWalkingRunning)
                samples.append(HKQuantitySample(type: dt,
                    quantity: HKQuantity(unit: .meter(), doubleValue: distanceM), start: start, end: end))
            }
            try await builder.addSamples(samples)
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {}
    }
    #endif

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
