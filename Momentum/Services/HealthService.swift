import Foundation
import HealthKit
import SwiftData

/// Apple Health, one direction out and signals only in.
///
/// **Out:** completed workouts are written to Health (PRD §8.6) — best-effort and non-blocking, so a
/// Health failure never affects the in-app save, and de-duplicated so a workout reaches Health once.
///
/// **In:** sleep, HRV, resting and walking heart rate, respiratory rate, wrist temperature, VO₂max,
/// body mass, steps. Deliberately **not** workouts. Health is a source of signals, never a source of
/// journal entries: connecting it imports nothing, backfills nothing, and creates no `Workout` rows,
/// so the recovery picture builds up day by day from the moment the athlete connects. The one place
/// workouts are read at all is `workoutSpans(from:to:)`, which takes time windows and nothing else so
/// a session isn't double-counted as incidental movement.
///
/// Authorization is opt-in (Settings → Apple Health); until then every call is a silent no-op.
@MainActor
final class HealthService: HealthServing {
    private let store = HKHealthStore()
    nonisolated private static let savedKey = "com.momentum.health.savedWorkoutIDs"
    /// Forget the write-dedupe ledger — called by the data wipes. Without this, a "Delete all
    /// data" reset left the set in UserDefaults and workouts logged afterwards were treated as
    /// already mirrored to Health, so they silently never reached it.
    nonisolated static func resetDedupe(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: savedKey)
    }

    /// Types we write. Reads (HR, resting HR, body mass, steps) are requested so a later slice can
    /// personalize from them; the write set is what gates `isAuthorized`.
    private static let shareTypes: Set<HKSampleType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.distanceCycling),
    ]
    private static let readTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),               // read workout WINDOWS only, to net exercise out of ambient totals
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
        // Recovery hub additions (RECOVERY-HUB-PLAN §3) — every read is best-effort; an empty
        // result means "absent", never zero.
        HKQuantityType(.respiratoryRate),              // recovery: overnight breaths/min vs personal norm
        HKQuantityType(.appleSleepingWristTemperature),// recovery: overnight wrist-temp deviation (Watch S8+)
        HKQuantityType(.oxygenSaturation),             // FYI vital: overnight SpO₂ — noticed, never scored
        HKQuantityType(.heartRateRecoveryOneMinute),   // fitness: HR fall in the minute after hard work
        HKQuantityType(.walkingHeartRateAverage),      // fatigue whisper: everyday-movement HR vs norm
        HKQuantityType(.timeInDaylight),               // education tile: morning light (watchOS 10+)
        HKCategoryType(.mindfulSession),               // education tile: down-regulation minutes
    ]

    /// True once the user has granted permission to share workouts. (HealthKit hides read status by
    /// design, so write authorization is the honest "connected" signal.)
    var isAuthorized: Bool {
        #if DEBUG
        // A demo-recovery launch renders scripted Health data — presenting a "Connect Apple
        // Health" ask over populated demo charts reads as broken (screenshot-verified). Demo IS
        // the connected experience.
        if Self.demoRecoveryScenario != nil { return true }
        #endif
        return HKHealthStore.isHealthDataAvailable()
            && store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do { try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes) }
        catch { return false }
        // Connecting is the whole action: no history is read, nothing is imported, no workout rows
        // are created. From here the recovery picture builds up day by day as Health accumulates.
        return isAuthorized
    }

    func save(_ workout: Workout, includeEnergy: Bool) async {
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
            if includeEnergy, let kcal = workout.calories, kcal > 0 {
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
            // Stamp our own writes so a Momentum workout in Health is identifiable as ours — by
            // other tools reading Health, and by us if we ever need to reconcile what we put there.
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
        if ProcessInfo.processInfo.arguments.contains("--health-recovery-strained") { return .demoStrained }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return .empty }
        let ms = HKUnit.secondUnit(with: .milli)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        // "Today's" vitals must actually be recent — a 2-day bound (overnight readings land the
        // next morning; one missed sync forgiven) so readiness never scores off a dead device's
        // last write. Absent-but-recent degrades gracefully: every field is optional by design.
        async let hrv = latest(.heartRateVariabilitySDNN, unit: ms, within: 2)
        async let hrvBase = average(.heartRateVariabilitySDNN, unit: ms, days: 30)
        async let rhr = latest(.restingHeartRate, unit: bpm, within: 2)
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

    /// The time spans of Health workouts inside one day, for netting exercise out of ambient step
    /// and energy totals.
    ///
    /// This reads workout *windows* and nothing else — no titles, no distances, no rows. It is not
    /// an import and must never become one: Health tells us when the athlete was busy so a session
    /// isn't double-counted as incidental movement, and that is the entire contract. Day-bounded and
    /// limited, so it stays cheap no matter how long a library it is reading.
    private func workoutSpans(from dayStart: Date, to dayEnd: Date) async -> [(start: Date, end: Date)] {
        let samples: [HKWorkout] = await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd)
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                      limit: 64, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        return samples
            .filter { $0.startDate < dayEnd }
            .map { (start: max($0.startDate, dayStart), end: min($0.endDate, dayEnd)) }
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

    /// Most recent sample, optionally bounded to the last `within` days. The bound keeps "today's"
    /// signals honest: without it, the last HRV a since-abandoned device wrote months ago would
    /// surface as the current reading and skew readiness. Slow-moving measures (body mass, VO₂max)
    /// pass no bound — their latest value stays meaningful across gaps.
    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit, within days: Int? = nil) async -> Double? {
        await withCheckedContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            let predicate = days.map {
                HKQuery.predicateForSamples(
                    withStart: Calendar.current.date(byAdding: .day, value: -$0, to: Date()), end: nil)
            }
            let query = HKSampleQuery(sampleType: HKQuantityType(id), predicate: predicate,
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

    /// Hours of actual sleep in the most recent night — unions the `asleep*` category samples from the
    /// last 18 hours (long enough to catch last night, short enough to exclude the night before). Naps
    /// fold in; "in bed" (awake) time is excluded. Multiple sources (Watch + phone + a ring) each write
    /// the same night, their intervals overlapping — so we merge into disjoint spans and sum those,
    /// counting every minute asleep once rather than double-counting. `nil` when there's no sleep.
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
                // Merge overlapping asleep intervals (from every source) into a union of disjoint spans,
                // then sum — so an overlap counted by both the Watch and a ring lands as one span, not two.
                let intervals = (samples as? [HKCategorySample] ?? [])
                    .filter { asleep.contains($0.value) }
                    .map { (start: $0.startDate, end: $0.endDate) }
                let seconds = Self.unionSeconds(intervals)
                continuation.resume(returning: seconds > 0 ? seconds / 3600 : nil)
            }
            store.execute(query)
        }
    }

    /// Which wearables are actually feeding the recovery signals — for the provenance line, so it
    /// can say "your Oura ring" instead of "your connected wearable" (owner ask 2026-08-15).
    ///
    /// Samples the recent signal types (HRV, resting HR, sleep, respiratory rate — the reads the
    /// hub actually consumes), collects each sample's `sourceRevision.source`, and maps through
    /// the pure `WearableKind.identify`. Ordered by contribution (most samples first) so the
    /// device doing the real work leads the sentence. Sources we can't name — the iPhone itself,
    /// unrecognized apps — simply don't appear, and the footnote keeps its generic wording.
    /// Reads metadata only: no values leave this function, just "which device wrote them".
    func signalSources(days: Int = 14) async -> [WearableKind] {
        #if DEBUG
        // Screenshot recipe: the demo recovery scenarios show a believable two-device setup.
        if Self.demoRecoveryScenario != nil { return [.appleWatch, .oura] }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        // The set of paired wearables doesn't change between tab visits, but this sweep is four
        // serial HKSampleQuerys (≤1,600 samples) at the head of the Health segment's rebuild
        // chain — cache it for an hour so stale-model rebuilds skip straight to the vitals
        // (perf audit 2026-08-16).
        if let cached = Self.sourcesCache, Date().timeIntervalSince(cached.at) < 3600 {
            return cached.kinds
        }
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let types: [HKSampleType] = [
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.respiratoryRate),
            HKCategoryType(.sleepAnalysis),
        ]
        var counts: [WearableKind: Int] = [:]
        for type in types {
            let samples: [HKSample] = await withCheckedContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
                let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                          limit: 400, sortDescriptors: nil) { _, samples, _ in
                    continuation.resume(returning: samples ?? [])
                }
                store.execute(query)
            }
            for s in samples {
                let source = s.sourceRevision.source
                if let kind = WearableKind.identify(bundleID: source.bundleIdentifier, name: source.name) {
                    counts[kind, default: 0] += 1
                }
            }
        }
        let kinds = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
        Self.sourcesCache = (kinds, Date())
        return kinds
    }

    /// One-hour memo for `signalSources` — see the note at its guard.
    private static var sourcesCache: (kinds: [WearableKind], at: Date)?

    // MARK: Recovery hub history (day-bucketed reads — RECOVERY-HUB-PLAN §3, §9 P1)

    /// How a day's samples collapse into its one honest value.
    enum DailyReduction: Sendable {
        /// Per-day median — robust to spot-check spikes (a single 200 ms HRV artifact, a stair-sprint
        /// walking-HR reading). The rule for vitals.
        case median
        /// Per-source daily sums, then the MAX across sources — a phone and a Watch both count the
        /// same steps, so summing across sources double-counts every stride. The rule for counts.
        case maxSourceSum
    }

    /// Day-bucketed history for a quantity over the last `days` local days (today inclusive) —
    /// the raw feed for `HealthBaselines` and the hub's sparklines. One value per day that has
    /// samples; days without data are simply absent, never zero. Sorted ascending.
    func dailyHistory(_ id: HKQuantityTypeIdentifier, unit: HKUnit, days: Int,
                      reduction: DailyReduction = .median) async -> [(day: Date, value: Double)] {
        #if DEBUG
        if let scenario = Self.demoRecoveryScenario,
           let demo = Self.demoDailyHistory(id, days: days, scenario: scenario) { return demo }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date()))
            ?? Date().addingTimeInterval(-Double(days) * 86_400)
        let samples = await quantitySamples(id, unit: unit, from: cutoff)
        switch reduction {
        case .median:
            return Self.medianPerDay(samples.map { (date: $0.start, value: $0.value) }, calendar: calendar)
        case .maxSourceSum:
            return Self.maxSourceSumPerDay(samples.map { (date: $0.start, value: $0.value, source: $0.source) },
                                           calendar: calendar)
        }
    }

    /// HRV history with the sleep-window rule (RECOVERY-HUB-PLAN §11.2.5): each day's median prefers
    /// samples inside that night's sleep window, falling back to all-day when no sleep was recorded.
    /// A Watch writes daytime SDNN spot-checks that would otherwise bias the baseline — Oura/Whoop
    /// are overnight-only for exactly this reason. Days bucket to the morning the night ended, so a
    /// 23:30 reading counts toward tomorrow's readiness, not yesterday's.
    func hrvDailyHistory(days: Int) async -> [(day: Date, value: Double)] {
        #if DEBUG
        if let scenario = Self.demoRecoveryScenario,
           let demo = Self.demoDailyHistory(.heartRateVariabilitySDNN, days: days, scenario: scenario) {
            return demo
        }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let calendar = Calendar.current
        let dayCutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date()))
            ?? Date().addingTimeInterval(-Double(days) * 86_400)
        // Reach one day further back so the oldest night's pre-midnight segments are in frame.
        let fetchStart = calendar.date(byAdding: .day, value: -1, to: dayCutoff) ?? dayCutoff
        async let hrv = quantitySamples(.heartRateVariabilitySDNN,
                                        unit: .secondUnit(with: .milli), from: fetchStart)
        async let sleep = sleepSegments(from: fetchStart)
        let nights = Self.nightSpans(from: await sleep, calendar: calendar)
        return Self.nightPreferredMedianPerDay((await hrv).map { (date: $0.start, value: $0.value) },
                                               nights: nights, calendar: calendar)
            .filter { $0.day >= dayCutoff }
    }

    /// Per-night sleep reports for the last `days` mornings — duration is the shipped union-merge
    /// across every source (each asleep minute counts once); stages come from the SINGLE source with
    /// the largest asleep total that night, because cross-source stage unions produce impossible
    /// nights (a Watch's REM overlapping a ring's deep). Nights without stage data report duration
    /// only — the UI never pretends. Sorted ascending.
    func sleepNights(days: Int) async -> [SleepNight] {
        #if DEBUG
        if let scenario = Self.demoRecoveryScenario {
            return Self.demoSleepNights(days: days, scenario: scenario)
        }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let calendar = Calendar.current
        let dayCutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date()))
            ?? Date().addingTimeInterval(-Double(days) * 86_400)
        let fetchStart = calendar.date(byAdding: .day, value: -1, to: dayCutoff) ?? dayCutoff
        let segments = await sleepSegments(from: fetchStart)
        return Self.nightReports(from: segments, calendar: calendar).filter { $0.date >= dayCutoff }
    }

    /// Steps + active energy for one local day with workout windows netted out (pro-rated by overlap,
    /// clamped ≥ 0) — `DayStrain`'s ambient input, so a tracked run's steps never double as everyday
    /// load on top of its training load. Workout windows come from Health (our own saves echo there),
    /// clipped to the day. `nil` = no samples at all — absent, never zero.
    func ambientActivity(day: Date) async -> (steps: Double?, activeKcal: Double?) {
        #if DEBUG
        if Self.demoRecoveryScenario != nil { return Self.demoAmbientActivity(day: day) }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return (nil, nil) }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)

        async let stepsRaw = quantitySamples(.stepCount, unit: .count(), from: dayStart, to: dayEnd)
        async let kcalRaw = quantitySamples(.activeEnergyBurned, unit: .kilocalorie(),
                                            from: dayStart, to: dayEnd)
        let workoutSpans = await workoutSpans(from: dayStart, to: dayEnd)

        let steps = Self.ambientSum(await stepsRaw, nettingOut: workoutSpans)
        let kcal = Self.ambientSum(await kcalRaw, nettingOut: workoutSpans)
        return (steps, kcal)
    }

    /// The wearable's measured active energy inside one workout's window — the Watch's own numbers
    /// for exactly the minutes the athlete was playing (timed-sport calorie prefill). Each source is
    /// summed independently and the biggest wins: Watch and iPhone both write energy for the same
    /// minutes, and adding them double-counts. `nil` = no samples at all (no wearable, unauthorized,
    /// or the Watch hasn't synced yet) — absent, never zero, so callers can fall back to an estimate.
    func measuredActiveEnergy(start: Date, end: Date) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable(), end > start else { return nil }
        let samples = await quantitySamples(.activeEnergyBurned, unit: .kilocalorie(),
                                            from: start, to: end)
        guard !samples.isEmpty else { return nil }
        let bySource = Dictionary(grouping: samples, by: \.source)
            .mapValues { $0.reduce(0) { $0 + $1.value } }
        return bySource.values.max()
    }

    /// Daily step totals for the Trends "Daily movement" card. A STATISTICS query, deliberately —
    /// HealthKit's cumulative-sum statistics de-duplicate overlapping Watch + iPhone samples by
    /// source priority; summing raw samples would double-count every stepped-through run. Days
    /// with no samples come back as 0 (an honest gap), the whole array comes back empty when
    /// Health is unavailable or unauthorized.
    func dailySteps(daysBack: Int) async -> [(day: Date, steps: Double)] {
        #if DEBUG
        // Demo/sim runs: a deterministic, plausible fortnight-to-year of movement so the card can
        // be screenshotted (the simulator's Health store is empty). Same gate family as the
        // recovery demo data above.
        if Self.demoRecoveryScenario != nil
            || ProcessInfo.processInfo.arguments.contains("--seed-demo") {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            return (0..<max(1, daysBack)).reversed().compactMap { back in
                guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
                // Gentle weekly rhythm: bigger weekend days, one low day — deterministic by index.
                let i = Double(back)
                let steps = 8200 + 2600 * sin(i * 0.9) + (back % 7 == 2 ? -3400 : 0) + Double((back * 37) % 900)
                return (day: day, steps: max(1800, steps))
            }
        }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(max(1, daysBack) - 1), to: today),
              let end = cal.date(byAdding: .day, value: 1, to: today) else { return [] }
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(.stepCount),
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, _ in
                guard let collection else { continuation.resume(returning: []); return }
                var out: [(day: Date, steps: Double)] = []
                var sawAny = false
                collection.enumerateStatistics(from: start, to: today) { stats, _ in
                    let value = stats.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    if value > 0 { sawAny = true }
                    out.append((day: stats.startDate, steps: value))
                }
                // No steps at all across the whole window = no data source (or no read grant) —
                // report "nothing", not a flatline of zeros pretending to be a sedentary year.
                continuation.resume(returning: sawAny ? out : [])
            }
            store.execute(query)
        }
    }

    /// All samples of a quantity in a window, tagged with their writing source — the raw feed for
    /// the day-bucketed reductions above.
    private func quantitySamples(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                                 from start: Date, to end: Date? = nil)
        async -> [(start: Date, end: Date, value: Double, source: String)] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let query = HKSampleQuery(sampleType: HKQuantityType(id), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, _ in
                let out = (samples as? [HKQuantitySample])?.map {
                    (start: $0.startDate, end: $0.endDate,
                     value: $0.quantity.doubleValue(for: unit),
                     source: $0.sourceRevision.source.bundleIdentifier)
                } ?? []
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// Raw sleep segments (every source, every stage) since `start`, mapped to the pure
    /// `SleepSegment` mirror — the query machinery behind `sleepNights` and the HRV night rule.
    private func sleepSegments(from start: Date) async -> [SleepSegment] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let out = (samples as? [HKCategorySample])?.compactMap { s -> SleepSegment? in
                    guard let kind = SleepSegment.Kind(hkValue: s.value) else { return nil }
                    return SleepSegment(start: s.startDate, end: s.endDate, kind: kind,
                                        source: s.sourceRevision.source.bundleIdentifier)
                } ?? []
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    // MARK: Pure day-bucketed reductions (testable — no HealthKit types)

    /// Median of `values`; `nil` when empty. Even counts average the middle two.
    nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Pure reduction (testable): one median per local day — the vitals rule.
    nonisolated static func medianPerDay(_ samples: [(date: Date, value: Double)],
                                         calendar: Calendar) -> [(day: Date, value: Double)] {
        Dictionary(grouping: samples) { calendar.startOfDay(for: $0.date) }
            .compactMap { day, s in median(s.map { $0.value }).map { (day: day, value: $0) } }
            .sorted { $0.day < $1.day }
    }

    /// Pure reduction (testable): per-source daily sums, MAX across sources — the steps rule. A
    /// cumulative sum across sources would credit the same stride to the phone AND the Watch.
    nonisolated static func maxSourceSumPerDay(_ samples: [(date: Date, value: Double, source: String)],
                                               calendar: Calendar) -> [(day: Date, value: Double)] {
        Dictionary(grouping: samples) { calendar.startOfDay(for: $0.date) }
            .map { day, s -> (day: Date, value: Double) in
                let perSource = Dictionary(grouping: s) { $0.source }
                    .mapValues { $0.reduce(0) { $0 + $1.value } }
                return (day: day, value: perSource.values.max() ?? 0)
            }
            .sorted { $0.day < $1.day }
    }

    /// Pure union-merge (testable): overlapping/abutting intervals collapse into disjoint spans —
    /// the shipped sleep union-merge, extracted so nights and ambient netting share one truth.
    nonisolated static func mergedSpans(_ intervals: [(start: Date, end: Date)])
        -> [(start: Date, end: Date)] {
        var out: [(start: Date, end: Date)] = []
        for iv in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, iv.start <= last.end {
                out[out.count - 1].end = max(last.end, iv.end)   // overlaps/abuts — extend the open span
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// Seconds covered by the union of `intervals` — every minute counted once, never per-source.
    nonisolated static func unionSeconds(_ intervals: [(start: Date, end: Date)]) -> Double {
        mergedSpans(intervals).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// Pure bucketing (testable): the local day a sleep segment's night belongs to — the morning you
    /// woke from it. Segments ending 15:00 or later are an early bedtime for the night that ends
    /// tomorrow morning (mirroring the shipped 18-hour lookback, which reaches back to mid-afternoon);
    /// everything else — including afternoon naps — folds into the morning it ended.
    nonisolated static func nightKey(for end: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: end)
        guard calendar.component(.hour, from: end) >= 15 else { return day }
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }

    /// Pure assembly (testable): each night's outer sleep window (earliest asleep start → latest
    /// asleep end, all sources), keyed by wake-up morning — the HRV preference window.
    nonisolated static func nightSpans(from segments: [SleepSegment], calendar: Calendar)
        -> [Date: (start: Date, end: Date)] {
        var out: [Date: (start: Date, end: Date)] = [:]
        for seg in segments where seg.isAsleep {
            let key = nightKey(for: seg.end, calendar: calendar)
            if let cur = out[key] { out[key] = (min(cur.start, seg.start), max(cur.end, seg.end)) }
            else { out[key] = (seg.start, seg.end) }
        }
        return out
    }

    /// Pure reduction (testable): per-day median preferring samples inside that day's night window,
    /// falling back to all of the day's samples when no night was recorded or none overlap. Samples
    /// bucket by `nightKey`, so a pre-midnight overnight reading lands on the morning it served.
    nonisolated static func nightPreferredMedianPerDay(
        _ samples: [(date: Date, value: Double)],
        nights: [Date: (start: Date, end: Date)],
        calendar: Calendar) -> [(day: Date, value: Double)] {
        Dictionary(grouping: samples) { nightKey(for: $0.date, calendar: calendar) }
            .compactMap { day, all -> (day: Date, value: Double)? in
                let overnight = nights[day].map { w in
                    all.filter { $0.date >= w.start && $0.date <= w.end }
                } ?? []
                let picked = overnight.isEmpty ? all : overnight
                return median(picked.map { $0.value }).map { (day: day, value: $0) }
            }
            .sorted { $0.day < $1.day }
    }

    /// Pure assembly (testable): sleep segments → per-night reports. Duration union-merges every
    /// source; stages come from the single source with the largest asleep total (ties break by
    /// name, so the pick is deterministic); in-bed time union-merges separately.
    nonisolated static func nightReports(from segments: [SleepSegment],
                                         calendar: Calendar) -> [SleepNight] {
        Dictionary(grouping: segments) { nightKey(for: $0.end, calendar: calendar) }
            .compactMap { night, segs -> SleepNight? in
                let asleep = segs.filter(\.isAsleep)
                let asleepH = unionSeconds(asleep.map { (start: $0.start, end: $0.end) }) / 3600

                // Single best stage source: among sources that actually wrote stages, the one with
                // the most asleep time that night. A longer duration-only record (older Garmin)
                // still wins the union duration — it just can't blank out a real stage breakdown.
                let seconds: ([SleepSegment]) -> Double = {
                    $0.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                }
                let best = Dictionary(grouping: asleep) { $0.source }
                    .filter { $0.value.contains { $0.kind != .asleep } }
                    .max { (seconds($0.value), $1.key) < (seconds($1.value), $0.key) }
                var coreS, deepS, remS, awakeS: Double?
                if let best {
                    let own = segs.filter { $0.source == best.key }
                    coreS = seconds(own.filter { $0.kind == .core })
                    deepS = seconds(own.filter { $0.kind == .deep })
                    remS = seconds(own.filter { $0.kind == .rem })
                    awakeS = seconds(own.filter { $0.kind == .awake })
                }
                let inBed = segs.filter { $0.kind == .inBed }.map { (start: $0.start, end: $0.end) }
                let inBedS = inBed.isEmpty ? nil : unionSeconds(inBed)

                guard asleepH > 0 || inBedS != nil else { return nil }
                return SleepNight(date: night, asleepH: asleepH, coreS: coreS, deepS: deepS,
                                  remS: remS, awakeS: awakeS, inBedS: inBedS)
            }
            .sorted { $0.date < $1.date }
    }

    /// Pure netting (testable): a source's samples minus their overlap with workout windows
    /// (pro-rated by time inside the merged spans; instantaneous samples are all-in or all-out),
    /// then MAX across sources, clamped ≥ 0. `nil` when there are no samples — absent, never zero.
    nonisolated static func ambientSum(_ samples: [(start: Date, end: Date, value: Double, source: String)],
                                       nettingOut workoutSpans: [(start: Date, end: Date)]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let spans = mergedSpans(workoutSpans)
        let perSource = Dictionary(grouping: samples) { $0.source }.mapValues { segs in
            segs.reduce(0.0) { sum, s in
                let duration = s.end.timeIntervalSince(s.start)
                guard duration > 0 else {
                    let inside = spans.contains { s.start >= $0.start && s.start <= $0.end }
                    return sum + (inside ? 0 : s.value)
                }
                let overlap = spans.reduce(0.0) {
                    $0 + max(0, min(s.end, $1.end).timeIntervalSince(max(s.start, $1.start)))
                }
                return sum + s.value * max(0, 1 - overlap / duration)
            }
        }
        return max(0, perSource.values.max() ?? 0)
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
    // MARK: Demo synthetic history (RECOVERY-HUB-PLAN §9 P1's deferred populated-hub hook)

    /// The two synthetic recovery mornings the sim can launch with — the same args
    /// `recoverySignals()` short-circuits on, so the histories below and the live signals always
    /// tell one story. `nil` in a normal run: every history API falls through to its real query.
    enum DemoRecovery: Sendable {
        case rested     // `--health-recovery-demo` — a well-recovered athlete, fully populated
        case strained   // `--health-recovery-strained` — suppressed HRV, elevated RHR, short nights
    }

    nonisolated static var demoRecoveryScenario: DemoRecovery? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--health-recovery-demo") { return .rested }
        if args.contains("--health-recovery-strained") { return .strained }
        return nil
    }

    /// Deterministic pseudo-noise in [−scale, +scale] from pure day-index math — no RNG, no
    /// `Date.now` dependence, so the same launch renders the same charts (stable screenshots).
    nonisolated static func demoWobble(_ dayIndex: Int, _ scale: Double) -> Double {
        // Three incommensurate sines + a small integer-hash sawtooth: two sines alone read as a
        // perfect wave in the sparklines (screenshot-verified); biology is lumpier than that.
        let d = Double(dayIndex)
        let hash = Double((dayIndex &* 37) % 11 - 5) / 5.0
        return (sin(d * 1.7) * 0.45 + sin(d * 0.53 + 1.3) * 0.25
                + sin(d * 2.93 + 0.7) * 0.2 + hash * 0.18) * scale
    }

    /// Scripted day-bucketed history for the vitals the hub reads — ascending, one value per day,
    /// `days` long, values in the units the app queries them with (ms, bpm, breaths/min, °C):
    /// exactly the shape the real reductions return. This morning's point lands on the matching
    /// `RecoverySignals.demo`/`.demoStrained` static, so the hero, tiles, and charts agree.
    /// `nil` for identifiers without a script, which fall through to the real query.
    nonisolated static func demoDailyHistory(_ id: HKQuantityTypeIdentifier, days: Int,
                                             scenario: DemoRecovery,
                                             now: Date = Date(),
                                             calendar: Calendar = .current)
        -> [(day: Date, value: Double)]? {
        let strained = scenario == .strained
        let value: (Int) -> Double   // input is days-ago; 0 = this morning
        switch id {
        case .heartRateVariabilitySDNN:
            // Rested: ~65 ms with a gentle upward drift into today (~68 this morning).
            // Strained: steady ~63 until a week ago, then sliding to ~46 — the suppressed trend.
            value = strained
                ? { 63 + demoWobble($0, 3) - ($0 < 8 ? Double(8 - $0) * 2.2 : 0) }
                : { 64.8 + Double(15 - $0) * 0.12 + demoWobble($0, 6) }
        case .restingHeartRate:
            // Rested: ~52 ± 2 bpm. Strained: ~49 climbing to ~55 over the last six mornings.
            value = strained
                ? { 49 + demoWobble($0, 1.4) + ($0 < 6 ? Double(6 - $0) : 0) }
                : { 51.6 + demoWobble($0, 1.8) }
        case .respiratoryRate:
            // The steadiest vital: ~14.2 ± 0.4 br/min; strained adds the classic pre-illness
            // rise over the last three nights (z ≈ +2 and beyond vs the learned norm).
            value = { 14.2 + demoWobble($0, 0.35) + (strained && $0 < 3 ? Double(3 - $0) * 0.3 : 0) }
        case .appleSleepingWristTemperature:
            // Absolute overnight wrist temp on a tight norm (deltas ~0); strained runs ~0.6 °C
            // warm the last two nights — illness-watch territory: lilac + words, never red.
            value = { 34.6 + demoWobble($0, 0.12) + (strained && $0 < 2 ? Double(2 - $0) * 0.3 : 0) }
        case .walkingHeartRateAverage:
            // Everyday-movement HR ~68 ± 3; strained drifts toward ~74 — fatigue whispering.
            value = { 68 + demoWobble($0, 2.8) + (strained && $0 < 5 ? Double(5 - $0) * 1.2 : 0) }
        default:
            return nil
        }
        let today = calendar.startOfDay(for: now)
        return (0..<max(days, 0)).reversed().compactMap { ago in
            calendar.date(byAdding: .day, value: -ago, to: today).map { (day: $0, value: value(ago)) }
        }
    }

    /// Scripted nights for the last 14 mornings — the shapes the real `sleepNights` assembly
    /// returns: stage splits near deep 18% / core 55% / REM 22% / awake 5% of the night (the three
    /// asleep stages sum exactly to the union duration), one short night, and one missing night
    /// (the hollow column). Last night matches the live `RecoverySignals` demo static.
    nonisolated static func demoSleepNights(days: Int, scenario: DemoRecovery,
                                            now: Date = Date(),
                                            calendar: Calendar = .current) -> [SleepNight] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(days, 0)).reversed().compactMap { ago in
            guard ago != 9 else { return nil }   // one missing night — a watch left on the charger
            guard ago < 14 || ago % 29 != 21 else { return nil }   // the deep past skips nights too
            guard let morning = calendar.date(byAdding: .day, value: -ago, to: today) else { return nil }
            let asleepH: Double
            if ago >= 14 {
                // Beyond the scripted fortnight (the sheet's month-to-year windows): a steady
                // ~7.5 h base with believable texture and the occasional genuinely short night.
                asleepH = 7.45 + demoWobble(ago, 0.55) + (ago % 11 == 3 ? -1.1 : 0)
            } else {
                switch scenario {
                case .rested:    // gently improving nights (older ≈ 7.7 h → recent ≈ 8.3 h) with one
                                 // 6.8 h dip — the 14-day debt reads ~2 h and "being paid down", not
                                 // the 5.4 h "building" wall the first screenshots showed.
                    asleepH = ago == 0 ? 7.33 : ago == 4 ? 6.8
                        : 7.72 + Double(13 - ago) * 0.05 + demoWobble(ago, 0.4)
                case .strained:  // a week of short nights sliding into last night's 5.4
                    asleepH = ago == 0 ? 5.4
                        : ago < 5 ? 5.7 + demoWobble(ago, 0.4)
                        : 6.6 + demoWobble(ago, 0.6)
                }
            }
            let asleepS = asleepH * 3600
            let awakeF = 0.05
            let deepF = 0.18 + demoWobble(ago + 5, 0.015)
            let remF = 0.22 + demoWobble(ago + 11, 0.02)
            let nightS = asleepS / (1 - awakeF)
            let deepS = nightS * deepF
            let remS = nightS * remF
            return SleepNight(date: morning, asleepH: asleepH,
                              coreS: asleepS - deepS - remS, deepS: deepS, remS: remS,
                              awakeS: nightS * awakeF, inBedS: nightS + 420)
        }
    }

    /// Scripted everyday movement: ~8.4–13.9k steps by weekday (the long-run Saturday and errand
    /// Thursday walk more than the desk-day Wednesday) plus a small date-derived wobble so four
    /// stacked rhythm weeks don't repeat exactly. Active kcal rides steps at a plausible ratio.
    nonisolated static func demoAmbientActivity(day: Date, calendar: Calendar = .current)
        -> (steps: Double?, activeKcal: Double?) {
        let base: [Double] = [9_200, 11_400, 12_600, 8_400, 13_200, 10_100, 13_900]  // Sun…Sat
        let weekday = (calendar.component(.weekday, from: day) - 1) % 7
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: day) ?? 0
        let steps = (base[weekday] + sin(Double(dayOfYear) * 0.9) * 550).rounded()
        return (steps: steps, activeKcal: (steps * 0.045).rounded())
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

// MARK: - Sleep primitives (RECOVERY-HUB-PLAN §3)

/// A source-tagged sleep segment — the pure mirror of `HKCategorySample` so night assembly is
/// testable without HealthKit.
struct SleepSegment: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case asleep     // asleepUnspecified — duration-only sources (older watchOS, some vendors)
        case core, deep, rem, awake
        case inBed      // phone-only bedtime tracking writes this and nothing else
    }
    let start: Date
    let end: Date
    let kind: Kind
    let source: String   // writing source's bundle id — the single-best-source stage rule keys on it

    /// Counts toward asleep duration (awake and in-bed time never do).
    var isAsleep: Bool { kind == .asleep || kind == .core || kind == .deep || kind == .rem }
}

extension SleepSegment.Kind {
    /// `HKCategoryValueSleepAnalysis` raw value → segment kind; unknown values are skipped.
    init?(hkValue: Int) {
        switch hkValue {
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: self = .asleep
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: self = .core
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: self = .deep
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: self = .rem
        case HKCategoryValueSleepAnalysis.awake.rawValue: self = .awake
        case HKCategoryValueSleepAnalysis.inBed.rawValue: self = .inBed
        default: return nil
        }
    }
}

/// One night of sleep as read from Health — the raw material `SleepReport` (P2) scores. SI units
/// except `asleepH` (hours — matching the shipped `RecoverySignals.sleepHours` convention).
struct SleepNight: Sendable, Equatable {
    let date: Date       // local day the night ended — the wake-up morning
    let asleepH: Double  // union-merged across every source; each asleep minute counted once
    let coreS: Double?   // stage seconds from the single best source; all nil = duration-only night
    let deepS: Double?
    let remS: Double?
    let awakeS: Double?
    let inBedS: Double?  // union-merged in-bed time; nil when no source wrote it
}
