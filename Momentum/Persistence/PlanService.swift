import Foundation
import SwiftData

/// Bridges the pure `PlanEngine` to SwiftData: builds the catalog snapshot, runs generation, and
/// persists the result into `TrainingPlan`/`PlannedSession`/`PlannedExercise` (PRD §9, §8.7).
@MainActor
enum PlanService {

    /// Regenerate and persist the plan for a profile, replacing any existing one.
    @discardableResult
    static func regenerate(for profile: UserProfile,
                           calibration: CalibrationSeed = .none,
                           startDate: Date = Date(),
                           in context: ModelContext) -> TrainingPlan {
        let catalogItems = catalog(in: context)
        let inputs = planInputs(from: profile)
        let generated = PlanEngine.generate(profile: inputs, catalog: catalogItems,
                                            calibration: calibration, startDate: startDate)
        return persist(generated, for: profile, startDate: startDate, in: context)
    }

    /// Snapshot the exercise library for the engine.
    static func catalog(in context: ModelContext) -> [ExerciseCatalogItem] {
        let all = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        return all.map { ex in
            ExerciseCatalogItem(
                name: ex.name,
                primaryMuscles: ex.primaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                secondaryMuscles: ex.secondaryMuscles.compactMap(MuscleGroup.init(rawValue:)),
                equipment: ex.equipment, category: ex.category, defaultRestS: ex.defaultRestS)
        }
    }

    static func planInputs(from p: UserProfile) -> PlanInputs {
        let disciplines = p.disciplines.compactMap(Discipline.init(rawValue:))
        func level(_ key: String) -> ExperienceLevel {
            ExperienceLevel(rawValue: p.experience[key] ?? "") ?? .some
        }
        return PlanInputs(
            disciplines: disciplines.isEmpty ? [.running] : disciplines,
            goal: p.goal, daysPerWeek: p.daysPerWeek, equipment: p.equipment,
            sessionMinutes: p.sessionMinutes, raceDate: p.raceDate,
            runningExperience: level(Discipline.running.rawValue),
            liftingExperience: level(Discipline.strength.rawValue))
    }

    static func persist(_ plan: GeneratedPlan, for profile: UserProfile,
                        startDate: Date, in context: ModelContext,
                        calendar: Calendar = .current) -> TrainingPlan {
        // Replace any existing plan.
        if let existing = profile.plan {
            context.delete(existing)
            profile.plan = nil
        }

        let exercisesByName = Dictionary(
            ((try? context.fetch(FetchDescriptor<Exercise>())) ?? []).map { ($0.name, $0) },
            uniquingKeysWith: { a, _ in a })

        let trainingPlan = TrainingPlan()
        trainingPlan.goal = profile.goal
        trainingPlan.disciplines = profile.disciplines
        trainingPlan.raceDate = profile.raceDate
        trainingPlan.p5kSPerKm = plan.p5kSPerKm

        let anchor = calendar.startOfDay(for: startDate)
        var sessions: [PlannedSession] = []
        for week in plan.weeks {
            for gen in week.sessions {
                let ps = PlannedSession()
                ps.date = calendar.date(byAdding: .day, value: week.index * 7 + gen.dayOffset, to: anchor) ?? anchor
                ps.discipline = gen.discipline
                ps.runType = gen.runType
                ps.targetDistanceM = gen.targetDistanceM
                ps.targetDurationS = gen.targetDurationS
                ps.targetPaceSPerKm = gen.targetPaceSPerKm
                ps.intervals = gen.intervals
                ps.rationale = gen.rationale
                ps.strengthTargets = gen.strengthTargets.enumerated().map { idx, ge in
                    let pe = PlannedExercise()
                    pe.order = idx
                    pe.exercise = exercisesByName[ge.exerciseName]
                    pe.targetSets = ge.targetSets
                    pe.targetRepLow = ge.repLow
                    pe.targetRepHigh = ge.repHigh
                    pe.targetRPE = ge.targetRPE
                    pe.targetPctRM = ge.targetPctRM
                    pe.progression = ge.progression
                    return pe
                }
                sessions.append(ps)
            }
        }
        trainingPlan.sessions = sessions
        context.insert(trainingPlan)
        profile.plan = trainingPlan
        try? context.save()
        return trainingPlan
    }
}
