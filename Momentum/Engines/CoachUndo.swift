import Foundation
import SwiftData

/// One-step undo for coach-applied plan changes. Before `CoachActions` mutates anything, the whole
/// plan state (profile inputs + every session, field by field) is captured as JSON; "Undo" restores
/// it exactly — including `lastAdaptedAt`, so rolling back an ease/bump also returns the weekly
/// adaptation budget. Uniform across every intent (a rebuild, a moved session, an injury window)
/// because it restores state rather than reversing operations.
@MainActor
enum CoachUndo {

    // MARK: - Snapshot shape (Codable — persisted on the receipt's ChatMessage)

    struct Snapshot: Codable, Equatable {
        // Profile inputs the coach can touch.
        var goal: String
        var disciplines: [String]   // a running goal may add running — undo restores the exact set
        var daysPerWeek: Int
        var sessionMinutes: Int
        var equipment: String
        var raceDate: Date?
        var raceDistanceM: Double?
        var goalFinishTimeS: Double?
        var preferredDays: [Int]
        var planIntensity: String?
        var injuryHistory: [String]
        var activeInjuryArea: String?
        var activeInjurySeverity: String?
        var activeInjuryUntil: Date?
        // The plan itself.
        var plan: PlanState?
        // Additive (2026-07-15, renewBlock): the declared weekly volume the renewal reassesses.
        // Optional so snapshots captured before this field still decode; `weeklyVolumeCaptured`
        // disambiguates "captured as nil" from "not captured" (optionals encode as absent).
        var weeklyRunVolumeM: Double? = nil
        var weeklyVolumeCaptured: Bool? = nil
        var fitnessDeclarationCaptured: Bool? = nil
        var fitnessDeclaredAt: Date? = nil
        var longestRunM: Double? = nil
        var timeLimitsCaptured: Bool? = nil
        var regularRunLimitS: Double? = nil
        var longRunLimitS: Double? = nil
        var illnessCaptured: Bool? = nil
        var illnessData: Data? = nil

        struct PlanState: Codable, Equatable {
            var name: String
            var goal: String
            var disciplines: [String]
            var raceDate: Date?
            var p5kSPerKm: Double
            var createdAt: Date
            var lastAdaptedAt: Date?
            var pausedUntil: Date?
            var pauseShiftedDates: [String: Date]? = nil
            var weekPhases: [String]
            var sessions: [SessionState]
            var blockIndex: Int? = nil   // additive: rolling-block counter (absent in old snapshots)
            // Additive (2026-09-07): the plan's identity and the latches a restore used to drop.
            // Restoring under the SAME id keeps every scalar-keyed sidecar (athlete state, season
            // pointer, metadata, intents) valid; a minted id orphaned them all.
            var id: UUID? = nil
            var isSelfCoached: Bool? = nil
            var blockStart: Date? = nil
            var goalRacePaceSPerKm: Double? = nil
            var lastPaceEasedAt: Date? = nil
            var lastRecalibratedAt: Date? = nil
            var pendingP5kSPerKm: Double? = nil
            var pendingP5kAt: Date? = nil
            var pendingP5kWorkoutID: UUID? = nil
            var paceEvidenceDates: [String: Date]? = nil
            var athleteState: AthleteState? = nil
        }

        /// The `PlanAthleteStateRecord` a plan was built with, so a restored plan keeps its
        /// threshold and personal curve instead of falling back to population numbers.
        struct AthleteState: Codable, Equatable {
            var thresholdSPerKm: Double?
            var thresholdMethod: String?
            var thresholdConfidence: String?
            var thresholdObservedAt: Date?
            var riegelExponent: Double?
            var durabilitySignal: String?
            var computedAt: Date
            var lastThresholdRecalibratedAt: Date?
        }

        struct SessionState: Codable, Equatable {
            var id: UUID
            var date: Date
            var discipline: String
            var sportType: String?
            var runType: String?
            var targetDistanceM: Double?
            var targetDurationS: Double?
            var targetPaceSPerKm: Double?
            var intervals: String?
            var status: String
            var rationale: String?
            var completedWorkoutID: UUID?
            var strength: [ExerciseState]
            var strengthLabel: String? = nil   // additive (2026-09-07): the split's day title
        }

        struct ExerciseState: Codable, Equatable {
            var order: Int
            var exerciseID: UUID?
            var targetSets: Int
            var targetRepLow: Int
            var targetRepHigh: Int
            var targetRPE: Double?
            var targetPctRM: Double?
            var progression: String
        }
    }

    // MARK: - Capture

    static func capture(_ profile: UserProfile) -> String? {
        var snap = Snapshot(
            goal: profile.goal.rawValue,
            disciplines: profile.disciplines,
            daysPerWeek: profile.daysPerWeek,
            sessionMinutes: profile.sessionMinutes,
            equipment: profile.equipment.rawValue,
            raceDate: profile.raceDate,
            raceDistanceM: profile.raceDistanceM,
            goalFinishTimeS: profile.goalFinishTimeS,
            preferredDays: profile.preferredDays,
            planIntensity: profile.planIntensity,
            injuryHistory: profile.injuryHistory,
            activeInjuryArea: profile.activeInjuryArea,
            activeInjurySeverity: profile.activeInjurySeverity,
            activeInjuryUntil: profile.activeInjuryUntil,
            plan: nil)
        snap.weeklyRunVolumeM = profile.weeklyRunVolumeM
        snap.weeklyVolumeCaptured = true
        snap.fitnessDeclarationCaptured = true
        snap.fitnessDeclaredAt = profile.fitnessDeclaredAt
        snap.longestRunM = profile.longestRunM
        snap.illnessCaptured = profile.modelContext?.container.schema.entities.contains(where: { $0.name == "PlanContinuityRecord" }) == true
        snap.illnessData = profile.continuity?.illnessData
        snap.timeLimitsCaptured = true
        snap.regularRunLimitS = profile.planPreferences?.regularRunLimitS
        snap.longRunLimitS = profile.planPreferences?.longRunLimitS
        if let plan = profile.plan {
            snap.plan = planState(of: plan)
        }
        guard let data = try? JSONEncoder().encode(snap) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The plan half of a snapshot on its own (2026-09-07): the shelf keeps a retired plan in this
    /// exact shape, so a previous plan reads back through the same decoder undo already trusts.
    static func planState(of plan: TrainingPlan) -> Snapshot.PlanState {
        let athlete = plan.modelContext.flatMap { PlanAthleteStateRecord.fetch(planID: plan.id, in: $0) }
        var state = Snapshot.PlanState(
                name: plan.name,
                goal: plan.goal.rawValue,
                disciplines: plan.disciplines,
                raceDate: plan.raceDate,
                p5kSPerKm: plan.p5kSPerKm,
                createdAt: plan.createdAt,
                lastAdaptedAt: plan.lastAdaptedAt,
                pausedUntil: plan.pausedUntil,
                weekPhases: plan.weekPhases,
                sessions: plan.sessions.map { s in
                    Snapshot.SessionState(
                        id: s.id, date: s.date,
                        discipline: s.discipline.rawValue,
                        sportType: s.sportType,
                        runType: s.runType?.rawValue,
                        targetDistanceM: s.targetDistanceM,
                        targetDurationS: s.targetDurationS,
                        targetPaceSPerKm: s.targetPaceSPerKm,
                        intervals: s.intervals,
                        status: s.status.rawValue,
                        rationale: s.rationale,
                        completedWorkoutID: s.completedWorkout?.id,
                        strength: s.strengthTargets.map { pe in
                            Snapshot.ExerciseState(
                                order: pe.order, exerciseID: pe.exercise?.id,
                                targetSets: pe.targetSets,
                                targetRepLow: pe.targetRepLow, targetRepHigh: pe.targetRepHigh,
                                targetRPE: pe.targetRPE, targetPctRM: pe.targetPctRM,
                                progression: pe.progression)
                        },
                        strengthLabel: s.strengthLabel)
                })
        state.blockIndex = plan.blockIndex
        state.pauseShiftedDates = plan.coachingState?.pauseShiftedDates
        state.id = plan.id
        state.isSelfCoached = plan.isSelfCoached
        state.blockStart = plan.blockStart
        state.goalRacePaceSPerKm = plan.goalRacePaceSPerKm
        state.lastPaceEasedAt = plan.lastPaceEasedAt
        state.lastRecalibratedAt = plan.lastRecalibratedAt
        state.pendingP5kSPerKm = plan.pendingP5kSPerKm
        state.pendingP5kAt = plan.pendingP5kAt
        state.pendingP5kWorkoutID = plan.coachingState?.pendingP5kWorkoutID
        state.paceEvidenceDates = plan.coachingState?.paceEvidenceDates
        if let athlete {
            state.athleteState = Snapshot.AthleteState(
                thresholdSPerKm: athlete.thresholdSPerKm, thresholdMethod: athlete.thresholdMethod,
                thresholdConfidence: athlete.thresholdConfidence, thresholdObservedAt: athlete.thresholdObservedAt,
                riegelExponent: athlete.riegelExponent, durabilitySignal: athlete.durabilitySignal,
                computedAt: athlete.computedAt, lastThresholdRecalibratedAt: athlete.lastThresholdRecalibratedAt)
        }
        return state
    }

    /// Only the single most recent applied change is undoable, app-wide: a newer change (from the
    /// chat or from Manage plan) invalidates every older snapshot, because they describe a world
    /// that no longer exists. Nulls every chat card's undo; the caller keeps its own if it wants one.
    static func makeSoleUndoPoint(in context: ModelContext) {
        // Only the messages that hold one: a long-tenured thread has thousands of rows and at
        // most one undo point among them.
        let holders = (try? context.fetch(FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.undoJSON != nil }))) ?? []
        for m in holders { m.undoJSON = nil }
    }

    // MARK: - Restore

    /// Put everything back exactly as captured. Returns false when the snapshot can't be decoded.
    @discardableResult
    static func restore(_ json: String, profile: UserProfile, in context: ModelContext,
                        restoreCloudRecovery: Bool = false) -> Bool {
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8)) else { return false }

        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }
        do {
            if snap.illnessCaptured == true {
                if restoreCloudRecovery {
                    PlanContinuityRecord.upsert(profileID: profile.id, in: context).illnessData = snap.illnessData
                } else {
                    let captured = try snap.illnessData.map { try JSONDecoder().decode(IllnessResponse.State.self, from: $0) }
                    try IllnessResponse.save(IllnessResponse.preservingRestrictions(IllnessResponse.state(for: profile), captured),
                                             profile: profile, in: context)
                }
            }
            profile.goal = Goal(rawValue: snap.goal) ?? profile.goal
            profile.disciplines = snap.disciplines
            profile.daysPerWeek = snap.daysPerWeek
            profile.sessionMinutes = snap.sessionMinutes
            if snap.timeLimitsCaptured == true {
                let preferences = PlanPreferencesRecord.upsert(profileID: profile.id, in: context)
                preferences.regularRunLimitS = snap.regularRunLimitS
                preferences.longRunLimitS = snap.longRunLimitS
            }
            profile.equipment = Equipment(rawValue: snap.equipment) ?? profile.equipment
            profile.raceDate = snap.raceDate
            profile.raceDistanceM = snap.raceDistanceM
            profile.goalFinishTimeS = snap.goalFinishTimeS
            profile.preferredDays = snap.preferredDays
            profile.planIntensity = snap.planIntensity
            // Undoing a plan edit must not clear a subsequently reported injury. Explicit
            // cloud resolution has already merged restrictions; injury return has its own gate.
            if restoreCloudRecovery || profile.activeInjuryArea == nil {
                profile.activeInjuryArea = snap.activeInjuryArea
                profile.activeInjurySeverity = snap.activeInjurySeverity
                profile.activeInjuryUntil = snap.activeInjuryUntil
            }
            profile.injuryHistory = Array(Set(profile.injuryHistory + snap.injuryHistory)).sorted()
            // Only restore when this snapshot actually captured it (older snapshots predate the field).
            if snap.weeklyVolumeCaptured == true { profile.weeklyRunVolumeM = snap.weeklyRunVolumeM }
            if snap.fitnessDeclarationCaptured == true {
                profile.longestRunM = snap.longestRunM
                PlanFitnessDeclarationRecord.set(snap.fitnessDeclaredAt, for: profile, in: context)
            }

            // Restore matching objects in place. Deleting and reinserting the whole relationship
            // graph inside an undo-enabled save can leave SwiftData with future backing data
            // while it snapshots the deletion. Keeping live instances also protects open views.
            let previousPlan = profile.plan
            if let old = previousPlan, old.id != snap.plan?.id {
                if let state = old.coachingState { context.delete(state) }
                if let state = PlanAthleteStateRecord.fetch(planID: old.id, in: context) { context.delete(state) }
            }
            if let planState = snap.plan {
                // The plan comes back under its own id, so any shelf record that recorded it as
                // finished (a renewal, a switch) now describes a plan that is current again. Remove
                // it, or Your plans would list the same plan as both current and previous.
                if let restoredID = planState.id {
                    let ghosts = (try? context.fetch(FetchDescriptor<PlanShelfRecord>(
                        predicate: #Predicate { $0.sourcePlanID == restoredID }))) ?? []
                    ghosts.forEach(context.delete)
                }
                let workouts = try context.fetch(FetchDescriptor<Workout>())
                let exercises = try context.fetch(FetchDescriptor<Exercise>())
                let workoutsByID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0) })
                let exercisesByID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

                let plan = previousPlan ?? TrainingPlan()
                if previousPlan == nil { context.insert(plan) }
                let previousSessions = plan.sessions
                var availableSessions = Dictionary(uniqueKeysWithValues: previousSessions.map { ($0.id, $0) })
                if let id = planState.id { plan.id = id }   // the same identity keeps every sidecar valid
                plan.name = planState.name
                plan.goal = Goal(rawValue: planState.goal) ?? .generalFitness
                plan.disciplines = planState.disciplines
                plan.raceDate = planState.raceDate
                plan.p5kSPerKm = planState.p5kSPerKm
                plan.createdAt = planState.createdAt
                plan.lastAdaptedAt = planState.lastAdaptedAt
                plan.pausedUntil = planState.pausedUntil
                let coachingState = PlanCoachingStateRecord.upsert(planID: plan.id, in: context)
                coachingState.pauseShiftedDates = planState.pauseShiftedDates ?? [:]
                plan.weekPhases = planState.weekPhases
                plan.blockIndex = planState.blockIndex ?? 0   // absent in pre-rolling-block snapshots
                plan.isSelfCoached = planState.isSelfCoached ?? false
                plan.blockStart = planState.blockStart
                plan.goalRacePaceSPerKm = planState.goalRacePaceSPerKm
                plan.lastPaceEasedAt = planState.lastPaceEasedAt
                plan.lastRecalibratedAt = planState.lastRecalibratedAt
                plan.pendingP5kSPerKm = planState.pendingP5kSPerKm
                plan.pendingP5kAt = planState.pendingP5kAt
                coachingState.pendingP5kWorkoutID = planState.pendingP5kWorkoutID
                coachingState.paceEvidenceDates = planState.paceEvidenceDates ?? [:]
                var sessions: [PlannedSession] = []
                for old in previousSessions {
                    old.completedWorkout?.plannedSession = nil
                    old.completedWorkout = nil
                }
                for s in planState.sessions {
                    let session = availableSessions.removeValue(forKey: s.id) ?? PlannedSession()
                    if session.modelContext == nil { context.insert(session) }
                    session.id = s.id
                    session.date = s.date
                    session.discipline = Discipline(rawValue: s.discipline) ?? .running
                    session.sportType = s.sportType
                    session.runType = s.runType.flatMap(RunType.init(rawValue:))
                    session.targetDistanceM = s.targetDistanceM
                    session.targetDurationS = s.targetDurationS
                    session.targetPaceSPerKm = s.targetPaceSPerKm
                    session.intervals = s.intervals
                    session.status = SessionStatus(rawValue: s.status) ?? .planned
                    session.rationale = s.rationale
                    session.strengthLabel = s.strengthLabel
                    let previousTargets = session.strengthTargets.sorted { $0.order < $1.order }
                    var targets: [PlannedExercise] = []
                    for (index, e) in s.strength.enumerated() {
                        let pe = index < previousTargets.count ? previousTargets[index] : PlannedExercise()
                        if pe.modelContext == nil { context.insert(pe) }
                        pe.order = e.order
                        pe.exercise = e.exerciseID.flatMap { exercisesByID[$0] }
                        pe.targetSets = e.targetSets
                        pe.targetRepLow = e.targetRepLow
                        pe.targetRepHigh = e.targetRepHigh
                        pe.targetRPE = e.targetRPE
                        pe.targetPctRM = e.targetPctRM
                        pe.progression = e.progression
                        targets.append(pe)
                    }
                    session.strengthTargets = targets
                    for old in previousTargets.dropFirst(targets.count) { context.delete(old) }
                    // Re-link credited workouts so completed history keeps its plan connection.
                    if let wid = s.completedWorkoutID, let workout = workoutsByID[wid] {
                        session.completedWorkout = workout
                        workout.plannedSession = session
                    }
                    sessions.append(session)
                }
                plan.sessions = sessions
                for old in availableSessions.values { context.delete(old) }
                profile.plan = plan
                // The athlete state the plan was built with, back under the restored id. A rebuild
                // removed the old record when it replaced the plan; without this the restored plan's
                // paces would re-derive from population numbers.
                if let a = planState.athleteState {
                    let record = PlanAthleteStateRecord.upsert(planID: plan.id, in: context)
                    record.thresholdSPerKm = a.thresholdSPerKm
                    record.thresholdMethod = a.thresholdMethod
                    record.thresholdConfidence = a.thresholdConfidence
                    record.thresholdObservedAt = a.thresholdObservedAt
                    record.riegelExponent = a.riegelExponent
                    record.durabilitySignal = a.durabilitySignal
                    record.computedAt = a.computedAt
                    record.lastThresholdRecalibratedAt = a.lastThresholdRecalibratedAt
                } else if let old = PlanAthleteStateRecord.fetch(planID: plan.id, in: context) {
                    context.delete(old)
                }
                // Season pointer, metadata and intents follow the restored plan the same way they follow
                // a rebuild; the caller saves.
                _ = try RunningPlanBackfill.prepareAfterLegacyPlanMutation(in: context)
            } else if let old = previousPlan {
                profile.plan = nil
                context.delete(old)
            }
            try IllnessResponse.enforce(in: context)
            try PlanMutation.save(context)
            return true
        } catch {
            context.rollback()
            return false
        }
    }
}
