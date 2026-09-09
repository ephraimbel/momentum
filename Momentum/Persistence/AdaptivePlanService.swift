import Foundation
import SwiftData

@MainActor
enum AdaptivePlanService {
    private static var preparing = Set<UUID>()
    static func isDue(_ plan: TrainingPlan?, now: Date = Date()) -> Bool {
        guard let plan, !plan.isSelfCoached, let state = plan.adaptiveState else { return false }
        return state.lastWeekStart < AdaptiveTrainingWeek.week(containing: now, calendar: state.calendar).start
    }
    static func prepare(profile: UserProfile?, services: Services, in context: ModelContext) async {
        guard ActiveWorkoutMarker.pendingID == nil, let profile, let plan = profile.plan, !plan.isSelfCoached,
              preparing.insert(plan.id).inserted else { return }
        let id = plan.id
        let profileID = profile.id
        defer { preparing.remove(id) }
        // Signal reads can suspend. Revalidate the plan identity before applying any result.
        let signals = isDue(plan) ? await services.health.recoverySignals() : .empty
        guard !Task.isCancelled, ActiveWorkoutMarker.pendingID == nil,
              let liveProfile = (try? context.fetch(FetchDescriptor<UserProfile>(predicate: #Predicate { $0.id == profileID })))?.first,
              liveProfile.plan?.id == id else { return }
        if refresh(profile: liveProfile, in: context, analytics: services.analytics, signals: signals) {
            PlanCoaching.reconcileMissed(liveProfile.plan, today: Date(), in: context,
                calendar: liveProfile.plan?.adaptiveState?.calendar ?? .current)
            if let plan = liveProfile.plan { WeeklyCoachCheckin.sweep(plan: plan, in: context) }
            services.notifications.schedulePlannedReminders(liveProfile.plan)
        }
    }

    /// One shared disclosure rule for board, session sheet, coach context and reminders.
    static func showsDetails(_ session: PlannedSession, plan: TrainingPlan?, now: Date = Date(),
                             calendar: Calendar = .current) -> Bool {
        guard let plan, !plan.isSelfCoached else { return true }
        if session.status == .completed || session.completedWorkout != nil { return true }
        let cal = plan.adaptiveState?.calendar ?? calendar
        let current = AdaptiveTrainingWeek.week(containing: now, calendar: cal)
        if session.date >= current.end { return false }
        if session.date < current.start { return true }
        guard let state = plan.adaptiveState else { return true }
        guard state.lastWeekStart >= current.start else { return false }
        return state.reviews.last(where: { $0.id == state.lastWeekKey }).map { $0.viewedAt != nil } ?? true
    }

    static func initialize(_ plan: TrainingPlan, profileID: UUID, now: Date, in context: ModelContext,
                           calendar: Calendar = .current) {
        guard !plan.isSelfCoached, plan.adaptiveState == nil,
              context.container.schema.entities.contains(where: { $0.name == "AdaptivePlanRecord" }) else { return }
        let row = AdaptivePlanRecord(planID: plan.id, profileID: profileID, now: now, calendar: calendar)
        let week = AdaptiveTrainingWeek.week(containing: now, calendar: calendar)
        row.baseline = baseline(plan, during: week)
        context.insert(row)
    }

    private static func baseline(_ plan: TrainingPlan, during week: DateInterval) -> [AdaptivePlanRecord.Baseline] {
        plan.sessions.filter { $0.date >= week.start && $0.date < week.end && $0.discipline == .running }
            .map { .init(id: $0.id, date: $0.date, distanceM: $0.targetDistanceM ?? 0) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Runs before missed-session reconciliation. Never regenerates the long-term framework,
    /// never moves dates, never touches a completed workout. The receipt and edits commit together.
    @discardableResult
    static func refresh(profile: UserProfile, now: Date = Date(), in context: ModelContext, analytics: AnalyticsServing? = nil, signals: RecoverySignals = .empty) -> Bool {
        guard let plan = profile.plan, !plan.isSelfCoached else { return true }
        do {
            if plan.adaptiveState == nil {
                try PlanMutation.perform(in: context) {
                    initialize(plan, profileID: profile.id, now: now, in: context)
                }
                return true // Existing users retain the current week at rollout.
            }
            guard let record = plan.adaptiveState else { return true }
            let cal = record.calendar
            let week = AdaptiveTrainingWeek.week(containing: now, calendar: cal)
            let key = AdaptiveTrainingWeek.key(now, calendar: cal)
            guard week.start > record.lastWeekStart, key != record.lastWeekKey else { return true }
            let current = plan.sessions.filter { $0.date >= week.start && $0.date < week.end }
            guard !current.isEmpty else { return true } // The lifecycle service owns block renewal.
            try PlanMutation.perform(in: context) {
                var e = try evidence(plan: plan, record: record, now: now, in: context,
                                     maxHR: profile.maxHR, restingHR: profile.restingHR)
                let tier = PlanIntensity(rawValue: profile.planIntensity ?? "") ?? .balanced
                if RecoveryAdaptation.decide(signals: signals, intensity: tier) != nil { e.poorRecovery = true }
                let open = current.filter { $0.status != .completed && $0.completedWorkout == nil }
                let runs = open.filter { $0.discipline == .running && $0.workoutType.map { $0 == .run } != false }
                let unit = DistanceUnit(rawValue: profile.distanceUnit) ?? .auto
                let beforeBrief = Dictionary(runs.map { ($0.id, PlanCoaching.brief(for: $0, distanceUnit: unit)) }, uniquingKeysWith: { a, _ in a })
                let before = runs.reduce(0) { $0 + ($1.targetDistanceM ?? 0) }
                let recentChange = plan.lastAdaptedAt.map { now.timeIntervalSince($0) < 7 * 86_400 } ?? false
                let decision = AdaptiveTrainingWeek.decide(e, frameworkM: before, alreadyAdapted: recentChange)
                let factor = before > 0 ? min(1, decision.maximumM / before) : 1
                var changes: [String] = []
                for s in runs {
                    let original = s.targetDistanceM ?? 0
                    let wasHard = [.tempo, .intervals, .progression, .race].contains(s.runType ?? .easy)
                    if decision.rest || factor == 0 {
                        s.status = .missed
                        s.rationale = decision.explanation
                        changes.append("\(s.date.formatted(.dateTime.weekday(.wide))): running replaced by rest.")
                    } else {
                        if factor < 1 {
                            s.targetDistanceM = original * factor
                            if let duration = s.targetDurationS { s.targetDurationS = duration * factor }
                            // Scaling an interval total without rebuilding its reps is unsafe.
                            s.intervals = nil
                        }
                        if decision.easyOnly || factor < 1 {
                            s.runType = .easy
                            s.intervals = nil
                            s.targetPaceSPerKm = PlanEngine.pace(.easy, p5k: plan.p5kSPerKm)
                        }
                        normalize(s)
                        if factor < 1 || (decision.easyOnly && wasHard) || s.discipline == .walking {
                            let unit = DistanceUnit(rawValue: profile.distanceUnit) ?? .auto
                            changes.append("\(s.date.formatted(.dateTime.weekday(.wide))): \(Formatters.distance(meters: original, unit: unit)) → \(Formatters.distance(meters: s.targetDistanceM ?? 0, unit: unit)) \(s.discipline == .walking ? "recovery walk" : "easy run").")
                            s.rationale = decision.explanation + " " + (changes.last ?? "")
                        }
                    }
                }
                // The receipt describes the final prescription after all existing safety and time limits.
                try RunPrescriptionBudget.enforcePreferences(in: context)
                try InjuryResponse.enforce(in: context)
                try IllnessResponse.enforce(in: context)
                changes = runs.compactMap { s in
                    let old = beforeBrief[s.id] ?? "Planned run"
                    let new = s.status == .missed ? "Rest" : PlanCoaching.brief(for: s, distanceUnit: unit)
                    guard old != new else { return nil }
                    return "\(s.date.formatted(.dateTime.weekday(.wide))): \(old) → \(new)."
                }
                // Close historical missed sessions without stacking them into the newly decided week.
                for s in plan.sessions where s.date < week.start && s.status != .completed && s.completedWorkout == nil {
                    s.status = .missed
                }
                let after = runs.filter { $0.status != .missed && $0.discipline == .running }
                    .reduce(0) { $0 + ($1.targetDistanceM ?? 0) }
                let outlook = PlanLifecycleService.feasibility(for: PlanBlueprint(profile: profile), profile: profile,
                    today: now, currentWeeklyM: e.recentWeeklyM, calendar: cal)
                let goalRead = decision.rest ? "Recovery comes first; goal readiness needs reassessment after you return."
                    : "Goal outlook: " + outlook.headline + " " + outlook.detail
                let duration = Int((e.actualDurationS ?? 0) / 60)
                let attendance = e.prescribedRuns > 0 ? "You completed \(e.completedRuns) of \(e.prescribedRuns) planned runs." : "There were no planned runs to compare last week."
                var summary = attendance + " Recorded running: \(Formatters.distance(meters: e.actualM, unit: unit)) over \(duration) minutes."
                if e.shortenedRuns > 0 { summary += " \(e.shortenedRuns) finished below their prescribed dose." }
                if e.movedRuns > 0 { summary += " \(e.movedRuns) sessions changed day." }
                let observations = AdaptiveTrainingWeek.observations(e)
                let anchor = AdaptiveTrainingWeek.week(containing: plan.blockStart ?? plan.createdAt, calendar: cal).start
                let phaseIndex = max(0, (cal.dateComponents([.day], from: anchor, to: week.start).day ?? 0) / 7)
                let phase = plan.weekPhases.indices.contains(phaseIndex)
                    ? PlanPhase(rawValue: plan.weekPhases[phaseIndex]) ?? .build : .build
                let explanation = [observations, decision.explanation].filter { !$0.isEmpty }.joined(separator: " ")
                let review = AdaptivePlanRecord.Review(id: key, weekStart: week.start, createdAt: now,
                    summary: summary, explanation: explanation, reason: decision.reason,
                    beforeM: before, afterM: after, changes: changes, evidence: e,
                    goalOutlook: goalRead, focus: AdaptiveTrainingWeek.focus(for: phase, decision: decision))
                var reviews = record.reviews
                guard !reviews.contains(where: { $0.id == key }) else { return }
                reviews.append(review); record.reviews = reviews
                record.lastWeekKey = key; record.lastWeekStart = week.start
                record.baseline = baseline(plan, during: week)
                if !changes.isEmpty { plan.lastAdaptedAt = now }
                AppNotification.post(kind: .coaching, title: "Your weekly review is ready",
                    body: summary + " " + explanation, on: now, in: context,
                    dedupeToken: "adaptive.\(plan.id).\(key)", daily: false, route: .plan, coachingPriority: 80, expiresAt: week.end)
                PlanMutation.afterCommit(in: context) {
                    analytics?.log(.adaptive(action: "next_week_generated", week: key, reason: decision.reason, goal: plan.goal))
                }
            }
            return true
        } catch {
            analytics?.log(.adaptive(action: "plan_generation_failure", week: "current", reason: "save_failed", goal: plan.goal))
            return false
        }
    }

    static func evidence(plan: TrainingPlan, record: AdaptivePlanRecord, now: Date,
                         in context: ModelContext, maxHR: Int? = nil, restingHR: Int? = nil) throws -> AdaptiveTrainingWeek.Evidence {
        let cal = record.calendar
        let end = AdaptiveTrainingWeek.week(containing: now, calendar: cal).start
        let start = cal.date(byAdding: .day, value: -7, to: end)!
        let historyStart = cal.date(byAdding: .day, value: -28, to: end)!
        let sessions = plan.sessions.filter { $0.date >= start && $0.date < end && $0.discipline == .running }
        let query = FetchDescriptor<Workout>(predicate: #Predicate { $0.startedAt >= historyStart && $0.startedAt < end })
        let history = try context.fetch(query).filter { $0.type.discipline == .running && $0.durationS.isFinite && $0.durationS > 0 && $0.id != ActiveWorkoutMarker.pendingID }
        let unique = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values
        let runs = unique.filter { $0.startedAt >= start }
        var e = AdaptiveTrainingWeek.Evidence()
        e.pain = record.requiresRecoveryCheckin
        e.illness = IllnessResponse.state(for: plan) != nil
        e.prescribedRuns = sessions.count
        e.completedRuns = sessions.filter { $0.status == .completed || $0.completedWorkout != nil }.count
        e.movedRuns = sessions.filter { $0.status == .moved }.count
        e.plannedM = sessions.reduce(0) { $0 + ($1.targetDistanceM ?? 0) }
        if record.lastWeekStart == start, !record.baseline.isEmpty {
            let initial = record.baseline
            e.prescribedRuns = initial.count
            e.plannedM = initial.reduce(0) { $0 + $1.distanceM }
            e.completedRuns = initial.filter { before in plan.sessions.contains { $0.id == before.id && ($0.status == .completed || $0.completedWorkout != nil) } }.count
            e.movedRuns = initial.filter { before in plan.sessions.contains { $0.id == before.id && !cal.isDate($0.date, inSameDayAs: before.date) } }.count
        }
        e.recordedRuns = runs.count
        e.actualDurationS = runs.reduce(0) { $0 + $1.durationS }
        e.aboveEasyHeartRateRuns = 0; e.prolongedHardRuns = 0
        let zones = maxHR.flatMap { HRZones.zones(maxHR: $0, restingHR: restingHR) }
        e.actualM = runs.reduce(0) { $0 + measuredDistance($1) }
        let observedStart = max(historyStart, AdaptiveTrainingWeek.week(containing: plan.blockStart ?? plan.createdAt, calendar: cal).start)
        let observedWeeks = max(1, min(4, (cal.dateComponents([.day], from: observedStart, to: end).day ?? 7) / 7))
        e.recentWeeklyM = unique.reduce(0) { $0 + measuredDistance($1) } / Double(observedWeeks)
        e.partialWeek = (plan.blockStart ?? plan.createdAt) > start
        e.missedWeeks = max(0, (cal.dateComponents([.day], from: record.lastWeekStart, to: end).day ?? 7) / 7 - 1)
        for w in runs {
            let feedback = WorkoutFeedbackRecord.fetch(workoutID: w.id, in: context)
            e.pain = e.pain || (feedback?.pain == true && record.requiresRecoveryCheckin)
            e.illness = e.illness || (feedback?.illness == true && record.requiresRecoveryCheckin)
            e.poorRecovery = e.poorRecovery || feedback?.recovery == 1
            e.unableToContinue = e.unableToContinue || feedback?.couldContinue == false
            if w.planFit == .harder || (w.perceivedEffort ?? 0) >= 8 { e.difficultRuns += 1 }
            let prescribed = feedback?.plannedDistanceM ?? w.plannedSession?.targetDistanceM
            let prescribedDuration = feedback?.plannedDurationS ?? w.plannedSession?.targetDurationS
            if let target = prescribed, target > 0 {
                if let actual = w.gps?.distanceM, actual.isFinite, actual < target * 0.8 { e.shortenedRuns += 1 }
            } else if let target = prescribedDuration, target > 0, w.durationS < target * 0.8 { e.shortenedRuns += 1 }
            let highEffort = (w.perceivedEffort ?? 0) >= 7
            if let target = prescribedDuration, target > 0, w.durationS > target * 1.2, highEffort {
                e.prolongedHardRuns = (e.prolongedHardRuns ?? 0) + 1; e.exceededEffort = true
            }
            let runType = feedback?.plannedRunType.flatMap(RunType.init(rawValue:)) ?? w.plannedSession?.runType
            if let runType, [.easy, .recovery, .long].contains(runType) {
                let paceTarget = feedback?.plannedPaceSPerKm ?? w.plannedSession?.targetPaceSPerKm
                if let pace = w.gps?.avgPaceSPerKm, pace.isFinite, pace > 0,
                   let target = paceTarget, target > 0, pace < target * 0.9, highEffort { e.exceededEffort = true }
                if let hr = w.gps?.avgHR, let zones, let maxHR,
                   hr <= maxHR, hr > zones[HRZones.zoneIndex(for: runType) - 1].bpm.upperBound {
                    e.aboveEasyHeartRateRuns = (e.aboveEasyHeartRateRuns ?? 0) + 1
                    // Weather, terrain and sensor error also affect HR. Require reported strain.
                    if highEffort { e.exceededEffort = true }
                }
            }
        }
        let checkins = try context.fetch(FetchDescriptor<DailyCheckin>(predicate: #Predicate { $0.date >= start && $0.date <= now }))
        e.poorRecovery = e.poorRecovery || checkins.sorted { $0.date > $1.date }.prefix(2).contains { $0.energy == .low || $0.legs == .sore }
        if let readiness = ReadinessTodayCache.today(now: now, calendar: cal), readiness.score < 40 {
            e.poorRecovery = true
        }
        return e
    }

    private static func measuredDistance(_ workout: Workout) -> Double {
        guard let meters = workout.gps?.distanceM, meters.isFinite, meters > 0 else { return 0 }
        return meters
    }

    static func normalize(_ s: PlannedSession) {
        guard s.discipline == .running, s.workoutType.map({ $0 == .run }) != false,
              s.status != .completed, s.completedWorkout == nil,
              (s.targetDistanceM ?? 0) < AdaptiveTrainingWeek.minimumRunM else { return }
        s.discipline = .walking; s.sportType = nil; s.runType = .recovery
        s.targetPaceSPerKm = nil; s.intervals = nil
        s.rationale = "Recovery walk. Today's safe running budget is below one mile; no extra distance is needed."
    }
}
