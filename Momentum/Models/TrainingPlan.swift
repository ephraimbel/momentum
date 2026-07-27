import Foundation
import SwiftData

@Model
final class TrainingPlan {
    var id: UUID = UUID()
    /// The athlete's own name for this block ("Austin Marathon") — shown as the Plan page title and
    /// stamped on plan sessions surfacing elsewhere (Today's banner), so plan work is unmistakable.
    /// Empty = unnamed; UI falls back to "Plan". Survives rebuilds (PlanService.persist carries it).
    var name: String = ""
    var goal: Goal = Goal.generalFitness
    var disciplines: [String] = []
    var raceDate: Date?
    var p5kSPerKm: Double = 360       // calibrated running pace (if running)
    var createdAt: Date = Date()
    var lastAdaptedAt: Date?          // last automatic load adaptation — gates auto-adapt to ≤1/week
    /// Set while the plan is paused (travel/illness — CoachActions): future sessions were shifted past
    /// this date and `reconcileMissed` stands down until it passes. Cleared by resume.
    var pausedUntil: Date?
    /// Rolling-block counter for open-ended plans (no race): 0 for the first block, +1 on each
    /// renewal (`PlanService.renewBlock`). Ignored for dated-race plans — they run one continuous
    /// macrocycle to race day. Additive: a plan stored before this field decodes as block 0.
    var blockIndex: Int = 0
    /// The day this block was generated from — the anchor for `weekPhases` and "Week N of M".
    /// Deliberately distinct from the earliest session, which can sit *earlier*: finished work
    /// carries across a rebuild (`PlanService.persist`), and a completed goal race often lands in the
    /// week before the block that follows it. Anchoring on the block keeps the macrocycle labels from
    /// sliding a week when history rides along. Additive: a plan stored before this field decodes as
    /// nil, and the Plan page falls back to the first session's week — what those plans were built on.
    var blockStart: Date?
    /// Macrocycle phase per plan week (PlanPhase raw values, index = weeks from `blockStart`) —
    /// the Plan page reads as a coached block: Base → Build → Recovery → Taper.
    var weekPhases: [String] = []
    /// Pace-recalibration evidence ledger (the multi-run confirmation rule): one strong run banks a
    /// candidate 5k-equivalent here; a second qualifying run within 14 days confirms and applies.
    /// The standard is 2–3 confirming sessions before raising fitness — never off one great day.
    /// Additive: plans stored before these fields decode as nil (no pending evidence).
    var pendingP5kSPerKm: Double?
    var pendingP5kAt: Date?
    /// Last *applied* automatic pace sharpening — caps recalibration to ≤1/week, so back-to-back
    /// strong runs can't compound the ≤3% per-update bound into a runaway ratchet.
    var lastRecalibratedAt: Date?
    /// Last consented pace easing (+2% per approval) — same weekly cap in the other direction; the
    /// ease is honest once, a slow downward ratchet if tapped after every session.
    var lastPaceEasedAt: Date?
    @Relationship(deleteRule: .cascade) var sessions: [PlannedSession] = []

    init() {}
}

/// A planned session uses its cardio fields **or** its `strengthTargets`, never both (§8.7).
@Model
final class PlannedSession {
    var id: UUID = UUID()
    var date: Date = Date()           // local day
    var discipline: Discipline = Discipline.running
    /// The precise sport (WorkoutType rawValue) when the athlete planned a specific one — swim, row,
    /// yoga, tennis, etc. `discipline` stays the coaching/analytics bucket; this carries the exact
    /// activity for display + matching. `nil` for AI-prescribed run/ride/walk/strength sessions.
    var sportType: String?
    var runType: RunType?
    var targetDistanceM: Double?
    var targetDurationS: Double?
    var targetPaceSPerKm: Double?
    var intervals: String?            // human-readable, e.g. "6x400m @ I"
    @Relationship(deleteRule: .cascade) var strengthTargets: [PlannedExercise] = []
    var status: SessionStatus = SessionStatus.planned
    var rationale: String?
    var completedWorkout: Workout?

    init() {}
}

extension PlannedSession {
    /// The exact planned sport, if one was chosen (else nil → falls back to `discipline` for display).
    var workoutType: WorkoutType? { sportType.flatMap(WorkoutType.init(rawValue:)) }
}

@Model
final class PlannedExercise {
    var order: Int = 0
    var exercise: Exercise?
    var targetSets: Int = 3
    var targetRepLow: Int = 8
    var targetRepHigh: Int = 12
    var targetRPE: Double?
    var targetPctRM: Double?          // % of e1RM (strength-focus)
    var progression: String = "double" // "linear" | "double" | "rpe" | "percent"
    /// Seconds to hold (plank) or carry (farmer's walk). Non-nil means this is a DURATION
    /// prescription and the rep range is not the athlete-facing target — read `prescriptionText`
    /// rather than formatting reps by hand. Optional with no default, so existing plans migrate
    /// lightweight and simply keep reading as rep-based.
    var targetHoldS: Int?

    init() {}

    /// The one place a prescription becomes words: "3 × 8–12" for a lift, "3 × 45s" for a hold.
    /// Every surface that shows a planned exercise (Today's confirm sheet, the Plan detail sheet,
    /// the onboarding reveal) formats through this — they each used to interpolate
    /// `targetSets × targetRepLow–targetRepHigh` inline, which is how a plank came to ask for
    /// 10–15 reps in three different places at once.
    var prescriptionText: String {
        if let hold = targetHoldS { return "\(targetSets) × \(hold)s" }
        if targetRepLow == targetRepHigh { return "\(targetSets) × \(targetRepLow)" }
        return "\(targetSets) × \(targetRepLow)–\(targetRepHigh)"
    }
}

extension WorkoutType {
    /// The sport Today's picker should show for a planned session — and therefore what its Start
    /// button says it will do.
    ///
    /// The picker used to be hardcoded to `.run` and never moved off it. On a running day that was
    /// invisible; on every other day the deck read "TODAY'S PLAN — Strength — 4 exercises" directly
    /// above a large primary button saying "Start run". The precise sport wins (a planned
    /// swim/yoga/row must not collapse into its discipline bucket); the bucket is the fallback.
    ///
    /// Lives here rather than beside `forDiscipline` in Enums.swift because that file is compiled
    /// into the watch and widget targets, which don't build `PlannedSession`.
    static func forPlanned(_ session: PlannedSession) -> WorkoutType {
        session.workoutType ?? forDiscipline(session.discipline)
    }
}
