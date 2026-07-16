import Foundation
import SwiftData

/// The athlete's record book (PRD §8.7) — reads the persisted `PersonalRecord` rows into the
/// current-best-per-type shelf, and backfills rows from workout history so athletes whose runs
/// predate record-persistence (or arrived via Health import) still own their bests.
///
/// Persist-on-save (`PersonalRecord.persist`, called from the save flows) remains the live path;
/// backfill replays history through the same dedupe so the two can never double-log.
@MainActor
enum RecordsBook {

    /// One current best, with when it was set and the workout that set it.
    struct Best: Identifiable, Sendable {
        let type: PRType
        let value: Double
        let achievedAt: Date
        var id: String { type.rawValue }
    }

    /// Whether a candidate value beats the incumbent for this record type.
    /// Times (fastest…) improve downward; distances/durations/weights improve upward.
    static func beats(_ candidate: Double, incumbent: Double, type: PRType) -> Bool {
        switch type {
        case .fastest1k, .fastest5k, .fastest10k: candidate < incumbent
        default: candidate > incumbent
        }
    }

    /// Reduce the full PR history to the current best per type (cardio types only — strength
    /// records are per-exercise and live on the strength surfaces).
    static func currentBests(_ prs: [PersonalRecord]) -> [Best] {
        let cardio: [PRType] = [.fastest1k, .fastest5k, .fastest10k, .longestRun, .longestDuration]
        return cardio.compactMap { type in
            let rows = prs.filter { $0.type == type && $0.value > 0 }
            guard var best = rows.first else { return nil }
            for row in rows where beats(row.value, incumbent: best.value, type: type) { best = row }
            return Best(type: type, value: best.value, achievedAt: best.achievedAt)
        }
    }

    /// Replay history once and persist any records it contains. Idempotent two ways: a versioned
    /// flag skips the replay after the first pass, and `PersonalRecord.persist` dedupes per
    /// (type, workout) so even a re-run can't double-log. Only rows that *improved* the running
    /// best are persisted, so the book reads as a true progression.
    static func backfillIfNeeded(in context: ModelContext,
                                 defaults: UserDefaults = .standard) {
        let flag = "com.momentum.records.backfill.v1"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        let all = ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .sorted { $0.startedAt < $1.startedAt }

        var bests: [PRType: Double] = [:]
        for workout in all {
            for candidate in cardioCandidates(workout) {
                if let incumbent = bests[candidate.type],
                   !beats(candidate.value, incumbent: incumbent, type: candidate.type) { continue }
                bests[candidate.type] = candidate.value
                PersonalRecord.persist([(type: candidate.type, value: candidate.value, exercise: nil)],
                                       workout: workout, in: context)
            }
        }
    }

    /// Persist any records ONE workout sets against the current shelf — the live path for
    /// workouts that bypass the in-app save flows (HealthKit imports; the backfill is one-shot,
    /// so without this every imported best after the first Progress visit was silently dropped).
    /// Same `beats` filter + `PersonalRecord.persist` dedupe as the backfill, so the book stays
    /// a true progression and a re-imported workout can't double-log.
    static func record(_ workout: Workout, in context: ModelContext) {
        let prs = (try? context.fetch(FetchDescriptor<PersonalRecord>())) ?? []
        var bests: [PRType: Double] = [:]
        for best in currentBests(prs) { bests[best.type] = best.value }
        for candidate in cardioCandidates(workout) {
            if let incumbent = bests[candidate.type],
               !beats(candidate.value, incumbent: incumbent, type: candidate.type) { continue }
            PersonalRecord.persist([(type: candidate.type, value: candidate.value, exercise: nil)],
                                   workout: workout, in: context)
        }
    }

    /// The record candidates one workout offers (same definitions as `CardioAchievements`).
    static func cardioCandidates(_ workout: Workout) -> [(type: PRType, value: Double)] {
        var out: [(PRType, Double)] = []
        // Longest session (any discipline, by moving time).
        if workout.durationS > 0 { out.append((.longestDuration, workout.durationS)) }
        guard let gps = workout.gps, gps.distanceM > 0 else { return out }
        if workout.type == .run { out.append((.longestRun, gps.distanceM)) }
        // Fastest benchmark windows are a RUNNING record only — a ride covers these distances far
        // faster and would corrupt the run 1K/5K/10K, so cycling never seeds them.
        if workout.type == .run {
            let sorted = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
            guard let first = sorted.first else { return out }
            var cumulative = 0.0
            var prev: LocationSample?
            let pts: [CardioMetrics.SamplePoint] = sorted.map { s in
                if let p = prev {
                    cumulative += Geo.distance(lat1: p.lat, lon1: p.lon, lat2: s.lat, lon2: s.lon)
                }
                prev = s
                return .init(t: s.t.timeIntervalSince(first.t), cumulativeM: cumulative)
            }
            for (meters, type) in [(1000.0, PRType.fastest1k), (5000.0, .fastest5k), (10000.0, .fastest10k)] {
                guard gps.distanceM >= meters,
                      let t = CardioMetrics.fastestWindow(pts, distanceM: meters) else { continue }
                out.append((type, t))
            }
        }
        return out
    }
}

extension PRType {
    /// Display name for the records shelf.
    var recordLabel: String {
        switch self {
        case .fastest1k: "Fastest 1K"
        case .fastest5k: "Fastest 5K"
        case .fastest10k: "Fastest 10K"
        case .longestRun: "Longest run"
        case .longestDuration: "Longest session"
        case .heaviestWeight: "Heaviest lift"
        case .bestE1RM: "Best e1RM"
        case .repMax: "Rep max"
        case .bestSetVolume: "Best set volume"
        case .bestSessionVolume: "Best session volume"
        }
    }
}
