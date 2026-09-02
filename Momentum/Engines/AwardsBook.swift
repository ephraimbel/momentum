import Foundation
import SwiftData

/// The awards ledger — the store-facing wrapper around the pure `AwardsEngine` (same split as
/// `RecordsBook` over the record math). `sync` rebuilds the snapshot from the store, evaluates,
/// and persists any newly-earned awards exactly once; call it wherever history changes (save
/// flows, account sync, and Progress/Profile visits). Idempotent two ways: earned rows are keyed by
/// `awardID`, and the engine is deterministic over the same history.
@MainActor
enum AwardsBook {

    /// Awards earned before this window ago are backfill — persisted already-seen, so an athlete
    /// updating the app (or restoring older Momentum history) isn't buried under a celebration
    /// for every milestone they crossed months ago. Anything fresher celebrates normally.
    static let celebrationWindowS: TimeInterval = 48 * 3600

    /// Deferred sync for the save flows: runs after the save cover has dismissed, so the
    /// history-sized snapshot walk never sits between the athlete's Save tap and the screen
    /// closing — and an unlock celebration presents over the destination screen instead of
    /// playing hidden behind the dismissing cover.
    static func syncSoon(delay: TimeInterval = 1.0) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            sync(in: PersistenceController.shared.container.mainContext)
        }
    }

    /// Recompute and persist newly-earned awards. Safe to call often — no-ops when nothing new.
    static func sync(in context: ModelContext, now: Date = Date()) {
        let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        let prs = (try? context.fetch(FetchDescriptor<PersonalRecord>())) ?? []
        let plan = ((try? context.fetch(FetchDescriptor<UserProfile>())) ?? []).first?.plan

        let snapshot = snapshot(workouts: workouts, records: prs, plan: plan, now: now)
        let earned = AwardsEngine.evaluate(snapshot)

        let existing = Set(((try? context.fetch(FetchDescriptor<EarnedAward>())) ?? []).map(\.awardID))
        var byID: [UUID: Workout]?   // built lazily — most syncs insert nothing
        var inserted = false
        for e in earned where !existing.contains(e.awardID) {
            if byID == nil { byID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0) }) }
            let fresh = now.timeIntervalSince(e.earnedAt) < celebrationWindowS
            context.insert(EarnedAward(awardID: e.awardID, earnedAt: e.earnedAt, seen: !fresh,
                                       workout: e.workoutID.flatMap { byID?[$0] }))
            inserted = true
        }
        if inserted { try? context.save() }
    }

    /// The engine snapshot for a given history — shared by `sync` and the award surfaces
    /// (gallery progress, profile shelf), so every reading comes from one definition.
    static func snapshot(workouts: [Workout], records: [PersonalRecord],
                         plan: TrainingPlan?, now: Date = Date(),
                         calendar: Calendar = .current) -> AwardsEngine.Snapshot {
        var counting = Set<Int>()
        let coords = startCoords(for: workouts)
        let activities = workouts.map { w in
            let dist = w.gps?.distanceM ?? 0
            if StreakCalculator.workoutQualifies(type: w.type, distanceM: dist, activeSeconds: w.durationS) {
                counting.insert(StreakCalculator.localDay(w.startedAt, calendar: calendar))
            }
            let strength = strengthFacts(for: w)
            return AwardsEngine.Activity(
                id: w.id, date: w.startedAt, type: w.type,
                distanceM: dist,
                elevationGainM: w.gps?.elevationGainM ?? 0,
                durationS: w.durationS,
                volumeKg: w.strength?.totalVolumeKg ?? 0,
                startHour: calendar.component(.hour, from: w.startedAt),
                workingSets: strength.sets,
                muscleBuckets: strength.buckets,
                startLat: coords[w.id]?.lat,
                startLon: coords[w.id]?.lon)
        }
        pruneStrengthMemo(live: workouts)

        // Streak days = qualifying days ∪ planned rest days — mirrors ProfileStats, so the streak
        // awards agree with the flame on the profile.
        var streakDays = counting
        if let plan {
            let today = StreakCalculator.localDay(now, calendar: calendar)
            let sessionDays = Set(plan.sessions.map { StreakCalculator.localDay($0.date, calendar: calendar) })
            streakDays.formUnion(StreakCalculator.plannedRestDays(sessionDays: sessionDays, today: today))
        }

        return AwardsEngine.Snapshot(
            activities: activities,
            records: records.map {
                AwardsEngine.RecordFact(type: $0.type, value: $0.value,
                                        achievedAt: $0.achievedAt, workoutID: $0.workout?.id)
            },
            planned: (plan?.sessions ?? []).map { session in
                let finish = session.completedWorkout
                return AwardsEngine.PlannedFact(
                    date: session.date, status: session.status,
                    isRace: session.runType == .race,
                    workoutID: finish?.id,
                    raceDistanceM: finish?.gps?.distanceM ?? session.targetDistanceM,
                    raceDurationS: finish?.durationS)
            },
            streakDays: streakDays,
            now: now)
    }

    // MARK: Strength-facts memo

    /// Per-workout working-set count + muscle buckets — the expensive half of the snapshot
    /// (faulting every session's exercises and sets). Cached for the process, keyed by the
    /// session's own scalars (`totalSets`/`totalVolumeKg`), so an edited session re-walks and
    /// everything else is a dictionary hit. Without this, every save tap and profile visit
    /// re-faulted the athlete's entire lifting history on the main actor.
    private struct StrengthFacts { let sets: Int; let buckets: Set<AwardsEngine.MuscleBucket> }
    private static var strengthMemo: [UUID: (key: Double, facts: StrengthFacts)] = [:]

    private static func strengthFacts(for w: Workout) -> (sets: Int, buckets: Set<AwardsEngine.MuscleBucket>) {
        guard let session = w.strength else { return (0, []) }
        let key = session.totalVolumeKg * 10_000 + Double(session.totalSets)
        if let cached = strengthMemo[w.id], cached.key == key {
            return (cached.facts.sets, cached.facts.buckets)
        }
        var workingSets = 0
        var buckets = Set<AwardsEngine.MuscleBucket>()
        for row in session.exercises {
            let completed = row.sets.count { $0.isComplete && $0.type == .working }
            workingSets += completed
            guard completed > 0, let exercise = row.exercise else { continue }
            for raw in exercise.primaryMuscles {
                guard let group = MuscleGroup(rawValue: raw) else { continue }
                buckets.formUnion(AwardsEngine.MuscleBucket.buckets(for: group))
            }
        }
        strengthMemo[w.id] = (key, StrengthFacts(sets: workingSets, buckets: buckets))
        return (workingSets, buckets)
    }

    private static func pruneStrengthMemo(live workouts: [Workout]) {
        guard strengthMemo.count > workouts.count else { return }
        let ids = Set(workouts.map(\.id))
        strengthMemo = strengthMemo.filter { ids.contains($0.key) }
    }

    // MARK: Start-coordinate memo (Wanderer)

    private static let geoMemoKey = "com.momentum.awards.geo.v1"

    /// Starting coordinate per GPS workout, extracted ONCE each and cached in UserDefaults —
    /// faulting every workout's full sample array on every sync would hard-jank big histories
    /// (page-load rule). Values: `[lat, lon]`, or `[]` for known no-fix workouts so they're never
    /// re-walked. Pruned to live workout ids, so wipes and deletions self-heal on the next sync.
    static func startCoords(for workouts: [Workout],
                            defaults: UserDefaults = .standard) -> [UUID: (lat: Double, lon: Double)] {
        var memo = (try? JSONDecoder().decode([String: [Double]].self,
                                              from: defaults.data(forKey: geoMemoKey) ?? Data())) ?? [:]
        var out: [UUID: (lat: Double, lon: Double)] = [:]
        var changed = false
        var live = Set<String>()
        for w in workouts {
            let key = w.id.uuidString
            live.insert(key)
            if let cached = memo[key] {
                if cached.count == 2 { out[w.id] = (cached[0], cached[1]) }
                continue
            }
            guard w.type.isGPS, let gps = w.gps,
                  let first = gps.samples.filter(\.accepted).min(by: { $0.t < $1.t }) else {
                memo[key] = []
                changed = true
                continue
            }
            memo[key] = [first.lat, first.lon]
            out[w.id] = (first.lat, first.lon)
            changed = true
        }
        if memo.count != live.count { memo = memo.filter { live.contains($0.key) }; changed = true }
        if changed { defaults.set(try? JSONEncoder().encode(memo), forKey: geoMemoKey) }
        return out
    }
}
