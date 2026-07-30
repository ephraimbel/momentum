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

        struct PlanState: Codable, Equatable {
            var name: String
            var goal: String
            var disciplines: [String]
            var raceDate: Date?
            var p5kSPerKm: Double
            var createdAt: Date
            var lastAdaptedAt: Date?
            var pausedUntil: Date?
            var weekPhases: [String]
            var sessions: [SessionState]
            var blockIndex: Int? = nil   // additive: rolling-block counter (absent in old snapshots)
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
        if let plan = profile.plan {
            snap.plan = Snapshot.PlanState(
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
                        })
                })
            snap.plan?.blockIndex = plan.blockIndex
        }
        guard let data = try? JSONEncoder().encode(snap) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Restore

    /// Put everything back exactly as captured. Returns false when the snapshot can't be decoded.
    @discardableResult
    static func restore(_ json: String, profile: UserProfile, in context: ModelContext) -> Bool {
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8)) else { return false }

        profile.goal = Goal(rawValue: snap.goal) ?? profile.goal
        profile.disciplines = snap.disciplines
        profile.daysPerWeek = snap.daysPerWeek
        profile.sessionMinutes = snap.sessionMinutes
        profile.equipment = Equipment(rawValue: snap.equipment) ?? profile.equipment
        profile.raceDate = snap.raceDate
        profile.raceDistanceM = snap.raceDistanceM
        profile.goalFinishTimeS = snap.goalFinishTimeS
        profile.preferredDays = snap.preferredDays
        profile.planIntensity = snap.planIntensity
        profile.injuryHistory = snap.injuryHistory
        profile.activeInjuryArea = snap.activeInjuryArea
        profile.activeInjurySeverity = snap.activeInjurySeverity
        profile.activeInjuryUntil = snap.activeInjuryUntil
        // Only restore when this snapshot actually captured it (older snapshots predate the field).
        if snap.weeklyVolumeCaptured == true { profile.weeklyRunVolumeM = snap.weeklyRunVolumeM }

        // Replace the plan wholesale with the captured one (state restore, not operation reversal).
        if let old = profile.plan {
            profile.plan = nil
            context.delete(old)
        }
        if let planState = snap.plan {
            let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
            let exercises = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
            let workoutsByID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0) })
            let exercisesByID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

            let plan = TrainingPlan()
            plan.name = planState.name
            plan.goal = Goal(rawValue: planState.goal) ?? .generalFitness
            plan.disciplines = planState.disciplines
            plan.raceDate = planState.raceDate
            plan.p5kSPerKm = planState.p5kSPerKm
            plan.createdAt = planState.createdAt
            plan.lastAdaptedAt = planState.lastAdaptedAt
            plan.pausedUntil = planState.pausedUntil
            plan.weekPhases = planState.weekPhases
            plan.blockIndex = planState.blockIndex ?? 0   // absent in pre-rolling-block snapshots
            context.insert(plan)

            var sessions: [PlannedSession] = []
            for s in planState.sessions {
                let session = PlannedSession()
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
                context.insert(session)
                for e in s.strength {
                    let pe = PlannedExercise()
                    pe.order = e.order
                    pe.exercise = e.exerciseID.flatMap { exercisesByID[$0] }
                    pe.targetSets = e.targetSets
                    pe.targetRepLow = e.targetRepLow
                    pe.targetRepHigh = e.targetRepHigh
                    pe.targetRPE = e.targetRPE
                    pe.targetPctRM = e.targetPctRM
                    pe.progression = e.progression
                    context.insert(pe)
                    session.strengthTargets.append(pe)
                }
                // Re-link credited workouts so completed history keeps its plan connection.
                if let wid = s.completedWorkoutID, let workout = workoutsByID[wid] {
                    session.completedWorkout = workout
                    workout.plannedSession = session
                }
                sessions.append(session)
            }
            plan.sessions = sessions
            profile.plan = plan
        }
        try? context.save()
        return true
    }
}
