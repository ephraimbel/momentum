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
        case .fastest1k, .fastest5k, .fastest10k, .fastestHalf, .fastestMarathon, .fastest50k:
            candidate < incumbent
        default: candidate > incumbent
        }
    }

    /// The record types this book owns — everything derived from a cardio workout. Strength records
    /// are per-exercise and live on the strength surfaces.
    static let cardioTypes: [PRType] = [.fastest1k, .fastest5k, .fastest10k, .fastestHalf,
                                        .fastestMarathon, .fastest50k, .longestRun, .longestDuration]

    /// Reduce the full PR history to the current best per type (cardio types only — strength
    /// records are per-exercise and live on the strength surfaces).
    static func currentBests(_ prs: [PersonalRecord]) -> [Best] {
        let cardio = cardioTypes
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
        // v4 (2026-07-26) REBUILDS rather than tops up. Every cardio record until now was measured
        // off a raw haversine walk over the stored fixes, which GPS jitter inflates by 3–40%: the
        // benchmark windows closed hundreds of metres early, so the stored "Fastest 5K" was minutes
        // faster than the athlete ever ran — and `beats` then defended that phantom against every
        // real record they went on to set. The corrected replay can't fix those rows in place, so
        // the machine-derived cardio rows are dropped and re-derived from history. Strength records
        // are per-exercise and untouched.
        //
        // (v3 re-replayed history for the 50K benchmark, 2026-07-22; v2 added half/marathon.)
        let flag = "com.momentum.records.backfill.v4"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        let all = ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .sorted { $0.startedAt < $1.startedAt }

        let owned = Set(cardioTypes)
        for pr in ((try? context.fetch(FetchDescriptor<PersonalRecord>())) ?? []) where owned.contains(pr.type) {
            context.delete(pr)
        }
        try? context.save()   // clear the shelf before replaying, so `persist`'s dedupe sees a clean slate

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
            // One reduction for the whole app (`GPSDetail.routePoints`): engine-consistent distance,
            // so a benchmark window can't close hundreds of metres early and mint a phantom PR that
            // `beats` then defends forever against the athlete's real ones.
            let pts = gps.samplePoints(type: workout.type)
            for (meters, type) in [(1000.0, PRType.fastest1k), (5000.0, .fastest5k), (10000.0, .fastest10k),
                                   (21_097.5, .fastestHalf), (42_195.0, .fastestMarathon),
                                   (50_000.0, .fastest50k)] {
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
        case .fastestHalf: "Fastest half"
        case .fastestMarathon: "Fastest marathon"
        case .fastest50k: "Fastest 50K"
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
