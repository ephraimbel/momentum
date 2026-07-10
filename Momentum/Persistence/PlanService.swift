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
        let inputs = planInputs(from: profile, startDate: startDate)
        let generated = PlanEngine.generate(profile: inputs, catalog: catalogItems,
                                            calibration: calibration, startDate: startDate)
        return persist(generated, for: profile, startDate: startDate, in: context)
    }

    /// Add tracked cross-training the engine doesn't program (swim/row/yoga…) as one recurring
    /// session per activity per week, on a day the structured plan didn't already use. Capped at
    /// `totalDaysPerWeek` distinct workout days so the athlete's chosen day count is honored — extras
    /// that don't fit are dropped rather than adding days. Each carries its precise `sportType`.
    static func addCrossTraining(_ types: [WorkoutType], to plan: TrainingPlan, startDate: Date = Date(),
                                 in context: ModelContext, totalDaysPerWeek: Int = 7,
                                 calendar: Calendar = .current) {
        guard !types.isEmpty else { return }
        let anchor = calendar.startOfDay(for: startDate)
        func dayIndex(_ d: Date) -> Int {
            calendar.dateComponents([.day], from: anchor, to: calendar.startOfDay(for: d)).day ?? 0
        }
        let weekCount = (plan.sessions.map { dayIndex($0.date) / 7 }.max() ?? 3) + 1

        for w in 0..<weekCount {
            let weekRange = (w * 7)..<((w + 1) * 7)
            var used = Set(plan.sessions.compactMap { s -> Int? in
                let di = dayIndex(s.date); return weekRange.contains(di) ? di % 7 : nil
            })
            for type in types {
                guard used.count < totalDaysPerWeek else { break }   // honor the chosen training-day count
                guard let off = (0..<7).first(where: { !used.contains($0) }) else { break }
                used.insert(off)
                let s = PlannedSession()
                s.date = calendar.date(byAdding: .day, value: w * 7 + off, to: anchor) ?? anchor
                s.sportType = type.rawValue
                s.discipline = type.discipline
                s.targetDurationS = 1800   // a 30-min default the athlete can adjust
                s.status = .planned
                s.rationale = "Cross-training — your call."
                plan.sessions.append(s)
                context.insert(s)
            }
        }
        try? context.save()
    }

    /// Rebuild the whole plan from `profile` — the one path used by both onboarding and the
    /// "edit plan settings" sheet. Shares the day budget between structured work and tracked add-ons
    /// (total distinct days ≤ daysPerWeek), preserves the calibrated 5k pace unless a fresh calibration
    /// is supplied, and re-adds the athlete's cross-training. Starts the plan from `startDate`.
    static func rebuild(for profile: UserProfile, calibration: CalibrationSeed? = nil,
                        startDate: Date = Date(), in context: ModelContext) {
        let extras = profile.crossTraining.compactMap(WorkoutType.init(rawValue:))
        let disciplines = profile.disciplines.compactMap(Discipline.init(rawValue:))
        let userDays = profile.daysPerWeek
        let structuredDays = max(1, min(userDays, max(disciplines.count, userDays - extras.count)))
        // Preserve the existing calibrated pace across a rebuild unless a new calibration is given.
        let seed = calibration ?? (profile.plan.map { CalibrationSeed(estimatedP5kSPerKm: $0.p5kSPerKm) } ?? .none)

        profile.daysPerWeek = structuredDays
        regenerate(for: profile, calibration: seed, startDate: startDate, in: context)
        profile.daysPerWeek = userDays   // restore the athlete's actual choice (plan + display)
        if let plan = profile.plan, !extras.isEmpty {
            addCrossTraining(extras, to: plan, startDate: startDate, in: context, totalDaysPerWeek: userDays)
        }
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

    static func planInputs(from p: UserProfile, startDate: Date = Date(),
                           calendar: Calendar = .current) -> PlanInputs {
        let disciplines = p.disciplines.compactMap(Discipline.init(rawValue:))
        func level(_ key: String) -> ExperienceLevel {
            ExperienceLevel(rawValue: p.experience[key] ?? "") ?? .some
        }
        // Map preferred weekdays (1 = Sun … 7 = Sat) to in-week offsets from the plan's start day.
        let anchorWeekday = calendar.component(.weekday, from: calendar.startOfDay(for: startDate))
        let offsets = p.preferredDays.map { ((($0 - anchorWeekday) % 7) + 7) % 7 }
        return PlanInputs(
            disciplines: disciplines.isEmpty ? [.running] : disciplines,
            goal: p.goal, daysPerWeek: p.daysPerWeek, equipment: p.equipment,
            sessionMinutes: p.sessionMinutes, raceDate: p.raceDate,
            runningExperience: level(Discipline.running.rawValue),
            liftingExperience: level(Discipline.strength.rawValue),
            raceDistanceM: p.raceDistanceM,
            currentWeeklyVolumeM: p.weeklyRunVolumeM, longestRunM: p.longestRunM,
            hybridPriority: p.hybridPriority.flatMap(HybridPriority.init(rawValue:)),
            muscleFocus: p.muscleFocus.compactMap(MuscleGroup.init(rawValue:)),
            preferredDayOffsets: offsets,
            intensity: PlanIntensity(rawValue: p.planIntensity ?? "") ?? .balanced,
            injuryHistory: p.injuryHistory.compactMap(InjuryArea.init(rawValue:)))
    }

    static func persist(_ plan: GeneratedPlan, for profile: UserProfile,
                        startDate: Date, in context: ModelContext,
                        calendar: Calendar = .current) -> TrainingPlan {
        // Replace any existing plan — but the athlete's name for it survives the rebuild.
        let carriedName = profile.plan?.name ?? ""
        if let existing = profile.plan {
            context.delete(existing)
            profile.plan = nil
        }

        let exercisesByName = Dictionary(
            ((try? context.fetch(FetchDescriptor<Exercise>())) ?? []).map { ($0.name, $0) },
            uniquingKeysWith: { a, _ in a })

        let trainingPlan = TrainingPlan()
        trainingPlan.name = carriedName
        trainingPlan.goal = profile.goal
        trainingPlan.disciplines = profile.disciplines
        trainingPlan.raceDate = profile.raceDate
        trainingPlan.p5kSPerKm = plan.p5kSPerKm
        // Persist the macrocycle (§6.1): taper/deload from the generator; the first two build weeks
        // read as Base (the foundation), everything else as Build.
        trainingPlan.weekPhases = plan.weeks.map { week in
            if week.isTaper { PlanPhase.taper.rawValue }
            else if week.isDeload { PlanPhase.recovery.rawValue }
            else if week.index < 2 { PlanPhase.base.rawValue }
            else { PlanPhase.build.rawValue }
        }

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
