import Foundation
import SwiftData

/// The persistent **memory of the athlete** — the layer that lets Momentum learn a user as they
/// train (see `docs/ATHLETE-MODEL.md`). One per `UserProfile`.
///
/// **Tier A — facts** are the structured fields below: derived deterministically from workout
/// history by `AthleteModelEngine` and fully recomputed on each workout, so they are always
/// reconstructable. **Tier B — memory** is the `notes` collection: short qualitative beliefs the
/// AI (and the user) author, which are *not* reconstructable and are the sync/backup priority.
/// `snapshots` is a weekly time series powering unlimited-horizon progress.
@Model
final class AthleteModel {
    var id: UUID = UUID()
    var updatedAt: Date = Date()
    var version: Int = 1                       // distillation version, for migration

    // MARK: Tier A — derived facts (recomputed each workout; see ATHLETE-MODEL.md §4)

    // Rhythm
    var trainingHourHistogram: [Int] = Array(repeating: 0, count: 24)  // counts by hour-of-day
    var weekdayHistogram: [Int] = Array(repeating: 0, count: 7)        // counts by weekday (1=Sun…7=Sat)
    var medianSessionMinutes: Double = 0
    var preferredSessionMinutes: Double = 0    // mode of completed durations, 15-min bins

    // Adherence
    var planAdherence28d: Double = 0           // completed / (completed + missed), trailing 28d
    var movedSessionRate28d: Double = 0
    /// Slips by ORIGINAL planned weekday (index = weekday−1, Sun…Sat) — incremented by
    /// `PlanCoaching.reconcileMissed` at the moment a session rolls, because the move erases the
    /// original date and no later recompute can recover it. Cumulative (all-time), unlike the
    /// recomputed facts above; feeds `AthleteModelEngine.avoidWeekdays` so the auto-spread stops
    /// planning the days this athlete demonstrably can't make. Additive + defaulted (schema rule).
    var missedWeekdayHistogram: [Int] = Array(repeating: 0, count: 7)

    // Discipline mix
    var disciplineShare: [String: Double] = [:]   // WorkoutType.raw -> fraction, trailing 56d
    var disciplineTrend: [String: Double] = [:]    // share delta vs the prior 56d period

    // Fitness trajectory (the "progress over time" backbone)
    var paceAtEffortTrendPct: Double = 0       // easy-run pace change at matched effort, 8wk (− = fitter)
    var e1rmTrendByExercise: [String: Double] = [:]  // exercise name -> % change, 8wk
    var weeklyVolumeTrendPct: Double = 0

    // Load / recovery
    var currentACWR: Double = 0
    /// Legacy persisted field name retained to avoid an unsafe SwiftData migration. Semantically this
    /// is low-confidence context: the lowest recent-to-usual ratio observed before at least three
    /// high-RPE easy sessions. It is not an overtraining, injury, or personal-safety threshold.
    var overreachThresholdACWR: Double = 1.5
    var priorHighStrainLoadRatio: Double {
        get { overreachThresholdACWR }
        set { overreachThresholdACWR = newValue }
    }
    var typicalRecoveryDays: Double = 1        // days after a hard session before quality returns

    // Achievement
    var prCountByMonth: [String: Int] = [:]    // "2026-06" -> count
    var lastPRAt: Date?

    // Continuity (training-disruption context — used to soften coaching, never shamed)
    var frequencyTrend28d: Double = 0          // sessions/wk delta; negative = fading
    var consecutiveMissed: Int = 0

    // Confidence bookkeeping — #workouts backing each signal key (see `Signal`)
    var signalSampleCounts: [String: Int] = [:]

    @Relationship(deleteRule: .cascade) var notes: [MemoryNote] = []
    @Relationship(deleteRule: .cascade) var snapshots: [FitnessSnapshot] = []

    init() {}
}

/// **Tier B** — one short, evolving belief about the athlete. Authored by the AI (and the user
/// via corrections). ≤140 chars, second person, no-shame, no medical claims (sanitized on ingest).
@Model
final class MemoryNote {
    var id: UUID = UUID()
    var category: String = MemoryCategory.habit.rawValue   // see `MemoryCategory`
    var text: String = ""
    var confidence: String = Confidence.emerging.rawValue  // see `Confidence`
    var source: String = MemorySource.ai.rawValue          // see `MemorySource`
    var evidenceKeys: [String] = []            // Tier-A signal keys / workout IDs supporting it
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isActive: Bool = true                  // retired notes kept (audit) but not surfaced/sent
    var pinned: Bool = false                   // user corrections pin to top; the AI must honor them

    init() {}
}

/// A weekly snapshot of fitness markers — the spine of the "how you've progressed" trajectory.
/// ≈52 rows/year; persisted because `ProgressInsights` only holds a rolling 8-week window.
@Model
final class FitnessSnapshot {
    var weekStart: Date = Date()
    var p5kEquivSPerKm: Double?                // running fitness proxy (Riegel-normalized)
    var topE1RMByLift: [String: Double] = [:]
    var weeklyLoad: Double = 0
    var weeklyDistanceM: Double = 0
    var acwr: Double = 0

    init() {}
}

// MARK: - Vocabularies (stored as raw strings for SwiftData/Supabase portability, per Enums.swift)

enum MemoryCategory: String, Codable, Sendable, CaseIterable {
    case habit       // when/how you train
    case preference  // what you choose
    case response    // how your body reacts to load
    case motivation  // what keeps you going
    case risk        // training disruption/fading — raw value retained for storage compatibility
    case identity    // the one-line "who you are as an athlete"
}

enum Confidence: String, Codable, Sendable, CaseIterable {
    case emerging, growing, confident
}

enum MemorySource: String, Codable, Sendable, CaseIterable {
    case ai, user, onboarding
}
