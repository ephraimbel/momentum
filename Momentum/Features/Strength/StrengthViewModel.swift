import Foundation
import SwiftData
import Observation

/// Bridges the `StrengthSessionEngine` actor to SwiftUI (PRD §4.4). Owns the engine + durable
/// store, mirrors a display snapshot, holds per-set editable drafts, and drives the rest timer.
@MainActor
@Observable
final class StrengthViewModel {
    struct Draft: Equatable { var weight = ""; var reps = ""; var rpe = "" }

    private let engine: StrengthSessionEngine
    private let context: ModelContext
    let weightUnit: WeightUnit
    let type: WorkoutType   // weight training / crossfit / HIIT — tags the saved workout

    /// Display snapshot of the live session.
    private(set) var exercises: [StrengthSessionEngine.LiveExercise] = []
    /// Editable input per set id.
    var drafts: [UUID: Draft] = [:]
    private var previousByRow: [UUID: [Int: PreviousPerformance.PrevSet]] = [:]
    private var plannedRepRange: [UUID: (low: Int, high: Int)] = [:]   // enables double-progression prefill
    /// Muscle targeting per catalog exercise, captured at add-time — drives the live muscle map.
    private var musclesByExercise: [UUID: (primary: [MuscleGroup], secondary: [MuscleGroup])] = [:]

    private(set) var workoutId: UUID?
    let startedAt = Date()

    // Rest timer (visible ring; the notification is the store/NotificationService's job).
    private(set) var restEndsAt: Date?
    private(set) var restTotal: TimeInterval = 0
    private var restExerciseName = "Rest"
    private let restActivity = RestActivityController()   // lock-screen / Dynamic Island mirror

    init(container: ModelContainer, type: WorkoutType = .strength, weightUnit: WeightUnit = .default()) {
        self.context = ModelContext(container)
        self.engine = StrengthSessionEngine(sink: StrengthWorkoutStore(modelContainer: container))
        self.weightUnit = weightUnit
        self.type = type
    }

    // MARK: Lifecycle

    func start() async {
        await engine.begin(type: type, now: startedAt)
        workoutId = ActiveWorkoutMarker.pendingID
        await refresh()
    }

    func finish() async -> UUID? {
        restActivity.end()
        NotificationService.cancelRestTimer()
        await engine.finish()
        return workoutId
    }

    /// User chose to throw the session away: delete the durable workout and clear the marker.
    func discard() async {
        restActivity.end()
        NotificationService.cancelRestTimer()
        await engine.discard()
        workoutId = nil
    }

    /// Anything worth confirming before exit? (logged sets or added exercises)
    var hasContent: Bool { completedSetCount > 0 || !exercises.isEmpty }

    // MARK: Mutations

    func addExercise(_ exercise: Exercise, repRange: (low: Int, high: Int)? = nil) async {
        let rowId = await engine.addExercise(exerciseId: exercise.id, name: exercise.name,
                                             category: exercise.category, defaultRestS: exercise.defaultRestS)
        musclesByExercise[exercise.id] = (exercise.primaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                                          exercise.secondaryMuscles.compactMap(MuscleGroup.init(rawValue:)))
        previousByRow[rowId] = PreviousPerformance.lastSession(forExerciseId: exercise.id, in: context)
        if let repRange { plannedRepRange[rowId] = repRange }   // planned ⇒ enable double-progression
        await addSetInternal(rowId: rowId)
        await refresh()
    }

    func addSet(rowId: UUID) async {
        await addSetInternal(rowId: rowId)
        await refresh()
    }

    /// Pre-load a planned strength day: each target exercise with its prescribed set count and
    /// rep target (PRD §4.4 "from today's plan day").
    func loadPlanned(_ session: PlannedSession) async {
        for pe in session.strengthTargets.sorted(by: { $0.order < $1.order }) {
            guard let exercise = pe.exercise else { continue }
            await addExercise(exercise, repRange: (pe.targetRepLow, pe.targetRepHigh))
            guard let rowId = exercises.last?.id else { continue }
            for _ in 1..<max(1, pe.targetSets) { await addSet(rowId: rowId) }
            if let row = exercises.first(where: { $0.id == rowId }) {
                for set in row.sets where (drafts[set.id]?.reps ?? "").isEmpty {
                    drafts[set.id, default: .init()].reps = String(pe.targetRepLow)
                }
            }
        }
    }

    private func addSetInternal(rowId: UUID) async {
        let snapshot = await engine.exercises
        guard let ex = snapshot.first(where: { $0.id == rowId }) else { return }
        let nextIndex = ex.sets.count

        var target = StrengthSessionEngine.SetTarget()
        if let prevRow = previousByRow[rowId], !prevRow.isEmpty {
            let prevTargets = prevRow.mapValues { StrengthSessionEngine.SetTarget(weightKg: $0.weightKg, reps: $0.reps) }
            if let range = plannedRepRange[rowId] {
                // Planned set: double-progress off last session (bump load once the range was topped out).
                target = StrengthSessionEngine.progressedTarget(previousSets: prevTargets, index: nextIndex,
                                                                repLow: range.low, repHigh: range.high)
            } else {
                target = prevTargets[nextIndex] ?? StrengthSessionEngine.SetTarget()
            }
        } else if let last = ex.sets.last(where: { $0.isComplete }) {
            target = .init(weightKg: last.weightKg, reps: last.reps)
        }

        if let setId = await engine.addSet(toExercise: rowId, prefill: target) {
            drafts[setId] = Draft(
                weight: target.weightKg.map { displayWeightString(kg: $0) } ?? "",
                reps: target.reps.map(String.init) ?? "",
                rpe: ""
            )
        }
    }

    func completeSet(rowId: UUID, setId: UUID) async {
        let draft = drafts[setId] ?? Draft()
        let weightKg = parseWeightToKg(draft.weight)
        let reps = Int(draft.reps)
        let rpe = Double(draft.rpe)

        await engine.completeSet(exerciseId: rowId, setId: setId, weightKg: weightKg, reps: reps, rpe: rpe)
        Haptics.light()

        let snapshot = await engine.exercises
        if let ex = snapshot.first(where: { $0.id == rowId }),
           let set = ex.sets.first(where: { $0.id == setId }) {
            startRest(seconds: set.restS, exerciseName: ex.name)
        }
        await refresh()
    }

    /// Un-log a completed set (the user tapped its ✓ again). Clears the rest timer it started.
    func uncompleteSet(rowId: UUID, setId: UUID) async {
        await engine.uncompleteSet(exerciseId: rowId, setId: setId)
        skipRest()
        Haptics.light()
        await refresh()
    }

    private func refresh() async {
        exercises = await engine.exercises
    }

    // MARK: Rest timer

    func startRest(seconds: TimeInterval, exerciseName: String = "Rest") {
        let now = Date()
        restTotal = seconds
        restExerciseName = exerciseName
        let endsAt = now.addingTimeInterval(seconds)
        restEndsAt = endsAt
        restActivity.start(exerciseName: exerciseName, startedAt: now, endsAt: endsAt, setsDone: completedSetCount)
        NotificationService.scheduleRestTimer(endsAt: endsAt, exerciseName: exerciseName)   // fires backgrounded
    }

    func skipRest() {
        restEndsAt = nil
        restActivity.end()
        NotificationService.cancelRestTimer()
    }

    func adjustRest(by delta: TimeInterval) {
        guard let end = restEndsAt else { return }
        let newEnd = max(Date(), end.addingTimeInterval(delta))
        restEndsAt = newEnd
        restTotal = max(1, restTotal + delta)
        restActivity.update(startedAt: newEnd.addingTimeInterval(-restTotal), endsAt: newEnd, setsDone: completedSetCount)
        NotificationService.scheduleRestTimer(endsAt: newEnd, exerciseName: restExerciseName)
    }

    func restRemaining(at now: Date) -> TimeInterval? {
        guard let end = restEndsAt else { return nil }
        return max(0, end.timeIntervalSince(now))
    }

    // MARK: Display helpers

    /// Live working-set volume (kg) from the snapshot.
    var liveVolumeKg: Double {
        exercises.reduce(0) { sum, ex in
            sum + ex.sets.reduce(0) { s, set in
                guard set.isComplete, set.type == .working, let w = set.weightKg, let r = set.reps
                else { return s }
                return s + w * Double(r)
            }
        }
    }

    var completedSetCount: Int {
        exercises.reduce(0) { $0 + $1.sets.filter(\.isComplete).count }
    }

    /// Live muscle activation for the body map (PRD §22 weighting). Completed working sets drive the
    /// real intensity; any added-but-unlogged exercise still gets a faint floor on its primary
    /// muscles, so the figure lights up the moment you pick an exercise and brightens as you log.
    var muscleActivation: [MuscleGroup: Double] {
        let entries = exercises.map { ex -> (primary: [MuscleGroup], secondary: [MuscleGroup], sets: Int) in
            let m = musclesByExercise[ex.exerciseId] ?? ([], [])
            let sets = ex.sets.filter { $0.isComplete && $0.type == .working }.count
            return (m.primary, m.secondary, sets)
        }
        var totals = StrengthMath.weeklySetsByMuscle(entries)
        for ex in exercises {
            for muscle in musclesByExercise[ex.exerciseId]?.primary ?? [] {
                totals[muscle] = max(totals[muscle] ?? 0, 0.6)
            }
        }
        return totals
    }

    /// Live volume in the user's display unit.
    var liveVolumeDisplay: Double {
        weightUnit == .lb ? liveVolumeKg * Formatters.lbPerKg : liveVolumeKg
    }

    /// Ghosted previous-session value for a set, e.g. "60 × 8".
    func ghost(rowId: UUID, setIndex: Int) -> String? {
        guard let prev = previousByRow[rowId]?[setIndex],
              let w = prev.weightKg, let r = prev.reps else { return nil }
        return "\(displayWeightString(kg: w)) × \(r)"
    }

    // MARK: Units

    func displayWeightString(kg: Double) -> String {
        switch weightUnit {
        case .kg:
            let v = (kg * 2).rounded() / 2
            return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        case .lb:
            return String(Int((kg * Formatters.lbPerKg).rounded()))
        }
    }

    private func parseWeightToKg(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return weightUnit == .lb ? value * Formatters.kgPerLb : value
    }

    var weightUnitLabel: String { weightUnit == .lb ? "lb" : "kg" }
}
