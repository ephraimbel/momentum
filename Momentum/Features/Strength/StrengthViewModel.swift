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

    /// Display snapshot of the live session.
    private(set) var exercises: [StrengthSessionEngine.LiveExercise] = []
    /// Editable input per set id.
    var drafts: [UUID: Draft] = [:]
    private var previousByRow: [UUID: [Int: PreviousPerformance.PrevSet]] = [:]

    private(set) var workoutId: UUID?
    let startedAt = Date()

    // Rest timer (visible ring; the notification is the store/NotificationService's job).
    private(set) var restEndsAt: Date?
    private(set) var restTotal: TimeInterval = 0

    init(container: ModelContainer, weightUnit: WeightUnit = .default()) {
        self.context = ModelContext(container)
        self.engine = StrengthSessionEngine(sink: StrengthWorkoutStore(modelContainer: container))
        self.weightUnit = weightUnit
    }

    // MARK: Lifecycle

    func start() async {
        await engine.begin(now: startedAt)
        workoutId = ActiveWorkoutMarker.pendingID
        await refresh()
    }

    func finish() async -> UUID? {
        await engine.finish()
        return workoutId
    }

    // MARK: Mutations

    func addExercise(_ exercise: Exercise) async {
        let rowId = await engine.addExercise(exerciseId: exercise.id, name: exercise.name,
                                             category: exercise.category, defaultRestS: exercise.defaultRestS)
        previousByRow[rowId] = PreviousPerformance.lastSession(forExerciseId: exercise.id, in: context)
        await addSetInternal(rowId: rowId)
        await refresh()
    }

    func addSet(rowId: UUID) async {
        await addSetInternal(rowId: rowId)
        await refresh()
    }

    private func addSetInternal(rowId: UUID) async {
        let snapshot = await engine.exercises
        guard let ex = snapshot.first(where: { $0.id == rowId }) else { return }
        let nextIndex = ex.sets.count

        var target = StrengthSessionEngine.SetTarget()
        if let prev = previousByRow[rowId]?[nextIndex] {
            target = .init(weightKg: prev.weightKg, reps: prev.reps)
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
        if let set = snapshot.first(where: { $0.id == rowId })?.sets.first(where: { $0.id == setId }) {
            startRest(seconds: set.restS)
        }
        await refresh()
    }

    private func refresh() async {
        exercises = await engine.exercises
    }

    // MARK: Rest timer

    func startRest(seconds: TimeInterval) {
        restTotal = seconds
        restEndsAt = Date().addingTimeInterval(seconds)
    }

    func skipRest() { restEndsAt = nil }

    func adjustRest(by delta: TimeInterval) {
        guard let end = restEndsAt else { return }
        restEndsAt = max(Date(), end.addingTimeInterval(delta))
        restTotal = max(1, restTotal + delta)
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
