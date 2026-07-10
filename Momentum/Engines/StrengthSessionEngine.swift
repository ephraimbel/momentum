import Foundation

/// Persistence + scheduling sink for the strength engine. Phase 1 backs this with SwiftData
/// (persist every completed set immediately, §8.4 durability) and `NotificationService` (schedule
/// the rest-timer local notification so it fires when backgrounded, §22/§24).
protocol StrengthWorkoutSink: Sendable {
    /// Create the durable `Workout` + `StrengthSession` and mark it the active (recoverable) workout.
    /// `type` is the gym sport (weight training / crossfit / HIIT) so the saved workout is tagged right.
    func beginWorkout(type: WorkoutType, startedAt: Date) async
    /// Create the durable `WorkoutExercise` row for a live exercise (keyed by `rowId`).
    func persistExercise(rowId: UUID, catalogExerciseId: UUID, order: Int, supersetGroup: Int?) async
    /// Persist a completed set immediately (the durability guarantee), attached to its row. Keyed by
    /// the live `setId` so re-logging the same set updates its row instead of creating a duplicate.
    func persistSetComplete(rowId: UUID, setId: UUID, setIndex: Int,
                            weightKg: Double?, reps: Int?, rpe: Double?, type: SetType) async
    /// Un-log a set the user unchecked: remove its persisted row so it no longer counts.
    func persistSetIncomplete(setId: UUID) async
    /// Schedule the rest-timer local notification so it fires when backgrounded.
    func scheduleRest(seconds: Double, exerciseName: String) async
    /// Finalize aggregates and clear the active-workout marker.
    func finishWorkout(totalVolumeKg: Double, totalSets: Int, durationS: TimeInterval) async
    /// Delete the in-progress workout entirely and clear the marker (user discarded it).
    func discardWorkout() async
}

struct NoopStrengthWorkoutSink: StrengthWorkoutSink {
    func beginWorkout(type: WorkoutType, startedAt: Date) async {}
    func persistExercise(rowId: UUID, catalogExerciseId: UUID, order: Int, supersetGroup: Int?) async {}
    func persistSetComplete(rowId: UUID, setId: UUID, setIndex: Int,
                            weightKg: Double?, reps: Int?, rpe: Double?, type: SetType) async {}
    func persistSetIncomplete(setId: UUID) async {}
    func scheduleRest(seconds: Double, exerciseName: String) async {}
    func finishWorkout(totalVolumeKg: Double, totalSets: Int, durationS: TimeInterval) async {}
    func discardWorkout() async {}
}

/// Strength capture engine (PRD §8.4 / §22). Owns the live logging session; no GPS.
/// Durable by contract: every completed set is persisted via the sink the moment it's logged.
actor StrengthSessionEngine {

    struct SetTarget: Equatable, Sendable {
        var weightKg: Double?
        var reps: Int?
        var hasValue: Bool { weightKg != nil || reps != nil }
    }

    struct LiveSet: Equatable, Sendable, Identifiable {
        var id = UUID()
        var index: Int
        var weightKg: Double?
        var reps: Int?
        var rpe: Double?
        var type: SetType = .working
        var isComplete = false
        var restS: Double
    }

    struct LiveExercise: Sendable, Identifiable {
        let id = UUID()
        let exerciseId: UUID
        let name: String
        let category: ExerciseCategory
        var supersetGroup: Int?
        var defaultRestS: Double
        var sets: [LiveSet] = []
    }

    private(set) var exercises: [LiveExercise] = []
    private(set) var startedAt: Date?
    private let sink: StrengthWorkoutSink

    init(sink: StrengthWorkoutSink = NoopStrengthWorkoutSink()) { self.sink = sink }

    // MARK: Pure helpers (unit-tested directly)

    /// Set prefill precedence (§22): today's plan target → this exercise's last session (same
    /// index) → empty.
    static func prefill(planTarget: SetTarget?, lastSession: SetTarget?) -> SetTarget {
        if let p = planTarget, p.hasValue { return p }
        if let l = lastSession { return l }
        return SetTarget(weightKg: nil, reps: nil)
    }

    /// Double progression (PRD §9.2, the adaptive half): when *every* completed set last session
    /// reached the top of the planned rep range, the exercise has earned a load bump — suggest the
    /// next weight up and reset reps to the bottom of the range. Otherwise repeat last session's
    /// numbers. Bounded by `stepKg` (the smallest meaningful jump), so it can never run away.
    /// Pure; used for the prefill of *planned* strength sets.
    static func progressedTarget(previousSets: [Int: SetTarget], index: Int,
                                 repLow: Int, repHigh: Int, stepKg: Double = 2.5) -> SetTarget {
        let base = previousSets[index] ?? previousSets.sorted { $0.key < $1.key }.first?.value ?? SetTarget()
        let completed = previousSets.values.filter { $0.weightKg != nil && $0.reps != nil }
        guard !completed.isEmpty, repHigh > 0,
              completed.allSatisfy({ ($0.reps ?? 0) >= repHigh }) else { return base }
        let topWeight = completed.compactMap(\.weightKg).max() ?? base.weightKg ?? 0
        return SetTarget(weightKg: topWeight + stepKg, reps: repLow)
    }

    /// Scheme-aware prefill for a *planned* exercise — the plan-level half of PRD §9.2's progression
    /// spec, dispatched on the prescription's `progression` string:
    ///  • **linear** (beginners): every completed set last session hit the target reps → add `stepKg`.
    ///  • **percent** (strength focus): weight = %1RM × the best e1RM shown last session, rounded to
    ///    the plate step — load advances automatically as e1RM grows, and backs off when it doesn't.
    ///  • **double** / anything else: classic double progression (`progressedTarget`).
    /// Pure and bounded; with no usable history each path degrades to repeating what's known.
    static func plannedTarget(scheme: String, previousSets: [Int: SetTarget], index: Int,
                              repLow: Int, repHigh: Int, targetPctRM: Double? = nil,
                              stepKg: Double = 2.5) -> SetTarget {
        let base = previousSets[index] ?? previousSets.sorted { $0.key < $1.key }.first?.value ?? SetTarget()
        let completed = previousSets.values.filter { $0.weightKg != nil && $0.reps != nil }
        switch scheme {
        case "linear":
            guard !completed.isEmpty, repLow > 0,
                  completed.allSatisfy({ ($0.reps ?? 0) >= repLow }) else { return base }
            let topWeight = completed.compactMap(\.weightKg).max() ?? base.weightKg ?? 0
            return SetTarget(weightKg: topWeight + stepKg, reps: repLow)
        case "percent":
            let bestE1RM = completed
                .compactMap { s -> Double? in
                    guard let w = s.weightKg, let r = s.reps else { return nil }
                    return StrengthMath.e1RM(weightKg: w, reps: r)
                }
                .max()
            guard let pct = targetPctRM, pct > 0, let e1rm = bestE1RM, e1rm > 0 else {
                return progressedTarget(previousSets: previousSets, index: index,
                                        repLow: repLow, repHigh: repHigh, stepKg: stepKg)
            }
            let rounded = ((pct * e1rm) / stepKg).rounded() * stepKg
            return SetTarget(weightKg: max(stepKg, rounded), reps: repLow)
        default:
            return progressedTarget(previousSets: previousSets, index: index,
                                    repLow: repLow, repHigh: repHigh, stepKg: stepKg)
        }
    }

    /// Autoregulated deload trigger (PRD §9.2): sustained RPE creep = the last TWO strength sessions
    /// both averaged near-max rated effort (mean RPE ≥ 8.5 over ≥3 rated working sets each). One
    /// brutal day never trips it — sustained means sustained.
    static func rpeCreep(recentSessionRPEs: [[Double]], threshold: Double = 8.5, minRatedSets: Int = 3) -> Bool {
        guard recentSessionRPEs.count >= 2 else { return false }
        return recentSessionRPEs.prefix(2).allSatisfy { rpes in
            rpes.count >= minRatedSets && rpes.reduce(0, +) / Double(rpes.count) >= threshold
        }
    }

    /// Default rest by category (§22): compound 150s, isolation 75s, otherwise 120s.
    /// A per-exercise override (or live user adjustment) wins.
    static func defaultRest(category: ExerciseCategory, override: Double? = nil) -> Double {
        if let o = override { return o }
        switch category {
        case .compound: return 150
        case .isolation: return 75
        case .cardio: return 120
        }
    }

    /// Total working-set volume of the live session.
    var totalVolumeKg: Double {
        StrengthMath.sessionVolume(workingSets)
    }

    var workingSets: [StrengthMath.WorkingSet] {
        exercises.flatMap { ex in
            ex.sets.compactMap { s -> StrengthMath.WorkingSet? in
                guard s.isComplete, s.type == .working, let w = s.weightKg, let r = s.reps else { return nil }
                return StrengthMath.WorkingSet(weightKg: w, reps: r)
            }
        }
    }

    // MARK: Live session orchestration

    func begin(type: WorkoutType = .strength, now: Date = Date()) async {
        guard startedAt == nil else { return }
        startedAt = now
        await sink.beginWorkout(type: type, startedAt: now)
    }

    @discardableResult
    func addExercise(exerciseId: UUID, name: String, category: ExerciseCategory,
                     defaultRestS: Double? = nil, supersetGroup: Int? = nil) async -> UUID {
        let rest = Self.defaultRest(category: category, override: defaultRestS)
        let ex = LiveExercise(exerciseId: exerciseId, name: name, category: category,
                              supersetGroup: supersetGroup, defaultRestS: rest)
        exercises.append(ex)
        await sink.persistExercise(rowId: ex.id, catalogExerciseId: exerciseId,
                                   order: exercises.count - 1, supersetGroup: supersetGroup)
        return ex.id
    }

    /// Append a set to an exercise; returns the new set's id (for the UI to track/edit/complete).
    @discardableResult
    func addSet(toExercise id: UUID, prefill: SetTarget = .init()) -> UUID? {
        guard let i = exercises.firstIndex(where: { $0.id == id }) else { return nil }
        let set = LiveSet(index: exercises[i].sets.count,
                          weightKg: prefill.weightKg, reps: prefill.reps,
                          restS: exercises[i].defaultRestS)
        exercises[i].sets.append(set)
        return set.id
    }

    /// Log a set: mark complete, persist immediately, and start the rest timer (§8.4).
    /// The light haptic is fired by the view model on the main actor.
    func completeSet(exerciseId: UUID, setId: UUID,
                     weightKg: Double?, reps: Int?, rpe: Double?) async {
        guard let ei = exercises.firstIndex(where: { $0.id == exerciseId }),
              let si = exercises[ei].sets.firstIndex(where: { $0.id == setId }) else { return }

        exercises[ei].sets[si].weightKg = weightKg
        exercises[ei].sets[si].reps = reps
        exercises[ei].sets[si].rpe = rpe
        exercises[ei].sets[si].isComplete = true

        let set = exercises[ei].sets[si]
        await sink.persistSetComplete(rowId: exercises[ei].id, setId: set.id, setIndex: set.index,
                                      weightKg: weightKg, reps: reps, rpe: rpe, type: set.type)
        await sink.scheduleRest(seconds: set.restS, exerciseName: exercises[ei].name)
    }

    /// Un-log a set the user unchecked: clear its completed flag in-memory and drop its durable row
    /// so it stops counting toward volume/muscles. Re-logging it persists a fresh row.
    func uncompleteSet(exerciseId: UUID, setId: UUID) async {
        guard let ei = exercises.firstIndex(where: { $0.id == exerciseId }),
              let si = exercises[ei].sets.firstIndex(where: { $0.id == setId }) else { return }
        exercises[ei].sets[si].isComplete = false
        await sink.persistSetIncomplete(setId: setId)
    }

    /// Finalize: roll up volume/sets and clear the recovery marker.
    func finish(now: Date = Date()) async {
        let working = workingSets
        let volume = StrengthMath.sessionVolume(working)
        let setCount = exercises.reduce(0) { $0 + $1.sets.filter(\.isComplete).count }
        await sink.finishWorkout(totalVolumeKg: volume, totalSets: setCount, durationS: elapsed(now: now))
    }

    /// Discard the whole session (delete the durable workout + clear the marker).
    func discard() async {
        await sink.discardWorkout()
    }

    func elapsed(now: Date = Date()) -> TimeInterval {
        guard let start = startedAt else { return 0 }
        return now.timeIntervalSince(start)
    }
}
