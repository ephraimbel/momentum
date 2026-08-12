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
    /// Planned prescription per exercise row — enables the scheme-aware progression prefill
    /// (PRD §9.2: linear / double / percent, each advancing off last session's logged sets)
    /// and the checklist header's "what the plan asks" line.
    struct PlannedPrescription {
        var repLow: Int
        var repHigh: Int
        var scheme: String = "double"
        var pctRM: Double?
        var targetSets: Int = 3
        var rpe: Double?
    }
    private var plannedPrescription: [UUID: PlannedPrescription] = [:]
    /// Muscle targeting per catalog exercise, captured at add-time — drives the live muscle map.
    private var musclesByExercise: [UUID: (primary: [MuscleGroup], secondary: [MuscleGroup])] = [:]
    /// Tracking mode per catalog exercise — a `weightReps` row without a weight isn't loggable
    /// yet (checking it off would record a barbell lift as bodyweight), so the checklist row
    /// asks for the weight instead.
    private var trackingByExercise: [UUID: TrackingMode] = [:]
    /// Sets the athlete has personally typed into. This is what separates "engaged with but
    /// never checked" (worth asking about at Finish) from untouched prefill — prefill is a
    /// TARGET, not performed work, and must never auto-log.
    private(set) var userEditedSets: Set<UUID> = []
    /// The exercise whose final set was just checked — the auto-advance beat the live view
    /// scrolls on. Cleared when a set is un-logged.
    private(set) var lastCompletedRowId: UUID?
    /// Mid-superset-round: the partner's open set for this round. A 4-set pair card is taller
    /// than the screen, so the live view scrolls this next move into place — the checklist
    /// principle that the next item presents itself.
    private(set) var roundNextSetId: UUID?

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

    func addExercise(_ exercise: Exercise, prescription: PlannedPrescription? = nil) async {
        _ = await addExerciseInternal(exercise, prescription: prescription)
        await refresh()
    }

    /// The add itself, WITHOUT the republish — and returning the new row's id rather than making the
    /// caller read it back off `exercises`, which only a refresh would have populated. `loadPlanned`
    /// builds a whole planned day out of this and refreshes once at the end.
    @discardableResult
    private func addExerciseInternal(_ exercise: Exercise,
                                     prescription: PlannedPrescription? = nil) async -> UUID {
        let rowId = await engine.addExercise(exerciseId: exercise.id, name: exercise.name,
                                             category: exercise.category, defaultRestS: exercise.defaultRestS)
        musclesByExercise[exercise.id] = (exercise.primaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                                          exercise.secondaryMuscles.compactMap(MuscleGroup.init(rawValue:)))
        trackingByExercise[exercise.id] = exercise.trackingMode
        previousByRow[rowId] = PreviousPerformance.lastSession(forExerciseId: exercise.id, in: context)
        if let prescription { plannedPrescription[rowId] = prescription }   // planned ⇒ scheme-aware progression
        await addSetInternal(rowId: rowId)
        return rowId
    }

    func addSet(rowId: UUID) async {
        await addSetInternal(rowId: rowId)
        await refresh()
    }

    /// Add a warm-up ("prep") set — inserted above the working sets, marked W, excluded from
    /// volume and PR math by every downstream reader. No prefill: a warm-up load is the
    /// athlete's call, never invented, so the row opens as a form.
    func addWarmupSet(rowId: UUID) async {
        if let setId = await engine.addSet(toExercise: rowId, prefill: .init(), type: .warmup) {
            drafts[setId] = Draft()
        }
        await refresh()
    }

    /// Pair an exercise with a newly picked partner as a superset. The partner arrives through
    /// the normal add path (previous-session prefill and all), then the pair is grouped and made
    /// adjacent. Rest changes meaning from here: it comes after the ROUND, not after each set.
    func pairSuperset(anchor rowId: UUID, with exercise: Exercise) async {
        await addExercise(exercise)
        guard let partnerId = exercises.last?.id, partnerId != rowId else { return }
        await engine.pairSuperset(rowId, partnerId)
        await refresh()
        Haptics.light()
    }

    /// Pair two exercises that are ALREADY in the session (no library trip).
    func pairExisting(_ anchorId: UUID, _ partnerId: UUID) async {
        await engine.pairSuperset(anchorId, partnerId)
        await refresh()
        Haptics.light()
    }

    /// The session's other standalone exercises — the picker offers these as one-tap links
    /// FIRST: the plan gave you five exercises, and running two of them as a pair is the most
    /// common superset there is.
    func supersetLinkCandidates(for rowId: UUID) -> [StrengthSessionEngine.LiveExercise] {
        exercises.filter { $0.id != rowId && $0.supersetGroup == nil }
    }

    /// Partner ideas from the catalog — the classic antagonist pairings (chest↔back,
    /// biceps↔triceps, quads↔hamstrings): one side rests while the other works, which is the
    /// whole point of a superset. Same-equipment partners rank first (you're already standing
    /// at the barbell), compounds before isolation; in-session exercises are excluded (they're
    /// offered above as links).
    func supersetSuggestions(for rowId: UUID) -> [Exercise] {
        guard let ex = exercises.first(where: { $0.id == rowId }) else { return [] }
        let anchorMuscles = Set(musclesByExercise[ex.exerciseId]?.primary ?? [])
        let targets = Set(anchorMuscles.flatMap { Self.antagonists[$0] ?? [] })
        guard !targets.isEmpty else { return [] }
        let inSession = Set(exercises.map(\.name))
        let catalog = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        let anchorEquipment = catalog.first(where: { $0.id == ex.exerciseId })?.equipment
        // Never suggest gear the athlete told us they don't have (mirrors PlanEngine's
        // allowedEquipment) — a bodyweight-only athlete must never see "Barbell Deadlift".
        let profileEquipment = ((try? context.fetch(FetchDescriptor<UserProfile>())) ?? [])
            .first?.equipment ?? .fullGym
        let allowed: Set<EquipmentType> = switch profileEquipment {
        case .fullGym: Set(EquipmentType.allCases)
        case .dumbbellsOnly: [.dumbbell, .bodyweight]
        case .homeMinimal: [.dumbbell, .bodyweight, .band, .kettlebell]
        case .bodyweight: [.bodyweight]
        }
        return catalog
            .filter { candidate in
                let muscles = candidate.primaryMuscles.compactMap(MuscleGroup.init(rawValue:))
                // A true partner hits the OTHER side and none of the anchor's own muscles —
                // "Back Squat" is never a superset partner for Barbell Back Squat.
                return !inSession.contains(candidate.name)
                    && allowed.contains(candidate.equipment)
                    && muscles.contains(where: targets.contains)
                    && !muscles.contains(where: anchorMuscles.contains)
            }
            .sorted { a, b in
                let aEq = a.equipment == anchorEquipment, bEq = b.equipment == anchorEquipment
                if aEq != bEq { return aEq }
                let aCompound = a.category == .compound, bCompound = b.category == .compound
                if aCompound != bCompound { return aCompound }
                return a.name < b.name
            }
            .prefix(5).map { $0 }
    }

    /// Why these two make sense together — push pairs with pull, so one side recovers while
    /// the other works. Knee-dominant pairs with hip-dominant, never with itself.
    private static let antagonists: [MuscleGroup: [MuscleGroup]] = [
        .chest: [.back], .back: [.chest], .shoulders: [.back],
        .biceps: [.triceps], .triceps: [.biceps], .forearms: [.biceps],
        .quads: [.hamstrings], .hamstrings: [.quads], .glutes: [.quads],
        .calves: [.quads],
    ]

    /// Break a superset back into standalone exercises (rest returns to per-set).
    func unlinkSuperset(rowId: UUID) async {
        await engine.unlinkSuperset(rowId)
        await refresh()
        Haptics.light()
    }

    /// Pre-load a planned strength day: each target exercise with its prescribed set count and
    /// rep target (PRD §4.4 "from today's plan day").
    func loadPlanned(_ session: PlannedSession) async {
        // Built with the non-republishing adds and refreshed ONCE at the end. Per-exercise and
        // per-set `refresh()` meant a six-lift day paid ~24 actor round-trips, each reassigning the
        // whole `exercises` array, before the screen had anything to draw — the planned-lift open
        // visibly hitched on its first frame. The work is identical; only the republishing is
        // collapsed. Prefill runs after the refresh for the same reason: it needs the finished set
        // list, which is exactly what the single refresh hands back.
        var repLowByRow: [UUID: Int] = [:]
        for pe in session.strengthTargets.sorted(by: { $0.order < $1.order }) {
            guard let exercise = pe.exercise else { continue }
            let rowId = await addExerciseInternal(exercise, prescription: PlannedPrescription(
                repLow: pe.targetRepLow, repHigh: pe.targetRepHigh,
                scheme: pe.progression, pctRM: pe.targetPctRM,
                targetSets: pe.targetSets, rpe: pe.targetRPE))
            for _ in 1..<max(1, pe.targetSets) { await addSetInternal(rowId: rowId) }
            repLowByRow[rowId] = pe.targetRepLow
        }
        await refresh()
        // Only sets the previous-session progression left blank — a real prefilled rep count is the
        // athlete's own history and outranks the prescription's floor.
        for row in exercises {
            guard let repLow = repLowByRow[row.id] else { continue }
            for set in row.sets where (drafts[set.id]?.reps ?? "").isEmpty {
                drafts[set.id, default: .init()].reps = String(repLow)
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
            if let rx = plannedPrescription[rowId] {
                // Planned set: progress off last session per the prescribed scheme (linear adds load
                // when target reps were hit; percent tracks %1RM off the shown e1RM; double bumps
                // once the rep range was topped out).
                target = StrengthSessionEngine.plannedTarget(scheme: rx.scheme, previousSets: prevTargets,
                                                             index: nextIndex, repLow: rx.repLow,
                                                             repHigh: rx.repHigh, targetPctRM: rx.pctRM)
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

        let snapshot = await engine.exercises
        if let ex = snapshot.first(where: { $0.id == rowId }) {
            // Flow the just-logged numbers forward into this exercise's still-empty sets —
            // type the weight once, and the rest of the exercise is pure check-off. Working
            // weights only, and only into working sets: a 95 lb warm-up must never become
            // the prescription for the top sets (or the reverse).
            let loggedType = ex.sets.first(where: { $0.id == setId })?.type
            if loggedType == .working {
                for other in ex.sets where other.id != setId && !other.isComplete && other.type == .working {
                    var d = drafts[other.id] ?? Draft()
                    if d.weight.isEmpty { d.weight = draft.weight }
                    if d.reps.isEmpty { d.reps = draft.reps }
                    drafts[other.id] = d
                }
            }
            let members = ex.supersetGroup.map { g in
                snapshot.filter { $0.supersetGroup == g }
            } ?? [ex]
            if let set = ex.sets.first(where: { $0.id == setId }) {
                if let partnerSet = openRoundPartnerSet(after: ex, set: set, in: snapshot) {
                    // Mid-superset-round: the next move is the partner's set — no rest yet, a
                    // ring still running from the previous round stands down, and the partner's
                    // row gets scrolled into place.
                    skipRest()
                    roundNextSetId = partnerSet
                } else {
                    roundNextSetId = nil
                    // A superset round rests for the pair's LONGEST prescription — finishing
                    // the round on the curl must not shortchange the bench's recovery.
                    let restSeconds = max(set.restS, members.map(\.defaultRestS).max() ?? set.restS)
                    startRest(seconds: restSeconds, exerciseName: ex.name)
                }
            }
            // Finishing the whole GROUP (the pair, or just this exercise when standalone) is its
            // own beat — a firmer pulse than the set tick, and the auto-advance signal.
            if members.allSatisfy({ !$0.sets.isEmpty && $0.sets.allSatisfy(\.isComplete) }) {
                lastCompletedRowId = rowId
                Haptics.success()
            } else {
                Haptics.light()
            }
        } else {
            Haptics.light()
        }
        await refresh()
    }

    /// The superset round rule: after a working set in a paired exercise, the partner's open
    /// set at the SAME working position is the next move — rest waits for the round. Returns
    /// that set's id (nil = round complete; warm-ups and unpaired extra sets rest normally).
    private func openRoundPartnerSet(after ex: StrengthSessionEngine.LiveExercise,
                                     set: StrengthSessionEngine.LiveSet,
                                     in snapshot: [StrengthSessionEngine.LiveExercise]) -> UUID? {
        guard let group = ex.supersetGroup, set.type == .working else { return nil }
        let position = ex.sets.filter { $0.type == .working }.firstIndex { $0.id == set.id } ?? 0
        for partner in snapshot where partner.id != ex.id && partner.supersetGroup == group {
            let working = partner.sets.filter { $0.type == .working }
            if position < working.count, !working[position].isComplete { return working[position].id }
        }
        return nil
    }

    /// Un-log a completed set (the user tapped its ✓ again). Clears the rest timer it started.
    func uncompleteSet(rowId: UUID, setId: UUID) async {
        await engine.uncompleteSet(exerciseId: rowId, setId: setId)
        if lastCompletedRowId == rowId { lastCompletedRowId = nil }
        roundNextSetId = nil
        skipRest()
        Haptics.light()
        await refresh()
    }

    // MARK: Checklist reads

    /// The athlete typed into this set themselves (weight/reps/rpe) — see `userEditedSets`.
    func markEdited(_ setId: UUID) { userEditedSets.insert(setId) }

    func prescription(rowId: UUID) -> PlannedPrescription? { plannedPrescription[rowId] }

    /// The section header's prescription line — what the plan asks of this exercise, e.g.
    /// "4 sets · 8–12 reps · RPE 8" or "4 sets · 4–6 reps · 82% 1RM". Nil for free sessions.
    func prescriptionLine(rowId: UUID) -> String? {
        guard let rx = plannedPrescription[rowId] else { return nil }
        let reps = rx.repLow == rx.repHigh ? "\(rx.repLow) reps" : "\(rx.repLow)–\(rx.repHigh) reps"
        var parts = ["\(rx.targetSets) sets", reps]
        if let pct = rx.pctRM {
            parts.append("\(Int((pct * 100).rounded()))% 1RM")
        } else if let rpe = rx.rpe {
            parts.append("RPE \(rpe == rpe.rounded() ? String(Int(rpe)) : String(format: "%.1f", rpe))")
        }
        return parts.joined(separator: " · ")
    }

    /// A `weightReps` exercise needs a weight before a set can be checked off — logging it
    /// weightless would record a barbell lift as bodyweight. Reps-only/timed rows never do.
    func weightExpected(rowId: UUID) -> Bool {
        guard let ex = exercises.first(where: { $0.id == rowId }) else { return false }
        return (trackingByExercise[ex.exerciseId] ?? .weightReps) == .weightReps
    }

    func isRowComplete(_ rowId: UUID) -> Bool {
        guard let ex = exercises.first(where: { $0.id == rowId }) else { return false }
        return !ex.sets.isEmpty && ex.sets.allSatisfy(\.isComplete)
    }

    /// Where the checklist continues — the first exercise with unchecked work.
    var firstIncompleteRowId: UUID? {
        exercises.first(where: { !$0.sets.isEmpty && !$0.sets.allSatisfy(\.isComplete) })?.id
    }

    /// Sets the athlete engaged with (typed into) but never checked — what the Finish dialog
    /// offers to log. Untouched prefill is a target, not performed work: it never auto-logs.
    var pendingEditedSets: [(rowId: UUID, setId: UUID)] {
        exercises.flatMap { ex in
            ex.sets
                .filter { !$0.isComplete && userEditedSets.contains($0.id)
                          && !(drafts[$0.id]?.reps ?? "").isEmpty }
                .map { (rowId: ex.id, setId: $0.id) }
        }
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
