import Foundation
import SwiftData

/// Symptom-led return support, not diagnosis or medical clearance. References and the distinction
/// between general-activity advice and return to training are in docs/PLAN-CONTINUITY.md.
@MainActor
enum IllnessResponse {
    enum Phase: String, Codable, Hashable { case resting, firstOuting, building }
    enum Kind: String, Codable { case respiratory, other }
    struct Prescription: Codable, Equatable {
        var runType: String?
        var distance: Double?
        var duration: Double?
        var pace: Double?
        var intervals: String?
        var rationale: String?
        init(_ session: PlannedSession) {
            runType = session.runType?.rawValue; distance = session.targetDistanceM
            duration = session.targetDurationS; pace = session.targetPaceSPerKm
            intervals = session.intervals; rationale = session.rationale
        }
        func apply(to session: PlannedSession) {
            session.runType = runType.flatMap(RunType.init(rawValue:))
            session.targetDistanceM = distance; session.targetDurationS = duration
            session.targetPaceSPerKm = pace; session.intervals = intervals; session.rationale = rationale
        }
    }
    struct State: Codable, Equatable {
        var episodeID = UUID()
        var phase: Phase = .resting
        var startedAt: Date
        var checkedAt: Date
        var needsClinicalAdvice = false
        var firstOutingID: UUID?
        var firstOutingEndedAt: Date?
        var returnStartedAt: Date?
        var completedOutings: [String: Date] = [:]
        var originals: [String: Prescription] = [:]
        var applied: [String: Prescription] = [:]
        var kind: Kind? = nil
    }
    struct Readiness {
        var improving = false
        var feverFreeWithoutMedicineFor24Hours = false
        var dailyActivitiesComfortable = false
        var concerningSymptoms = false
        var clinicianAdvisedReturn = false
        var exerciseWellTolerated = false
    }
    enum Failure: LocalizedError {
        case notReady, medicalAdvice, waitForResponse, moreEasyTraining, noPlan
        var errorDescription: String? {
            switch self {
            case .notReady: "Keep resting for now. Check in again when symptoms are improving, you have been fever-free without fever medicine for at least 24 hours, and normal daily activities feel comfortable."
            case .medicalAdvice: "Get medical advice before returning to exercise. Chest pain, difficulty breathing at rest or fainting need urgent medical attention."
            case .waitForResponse: "Complete your short easy outing, then allow at least 24 hours to check how you feel. Stop and check in sooner if symptoms return."
            case .moreEasyTraining: "Keep the return gentle. Before rebuilding, allow at least a week and complete two easy outings on separate days without symptoms returning."
            case .noPlan: "Create or restore your plan first."
            }
        }
    }

    static func state(for profile: UserProfile?) -> State? {
        guard let profile, let data = profile.continuity?.illnessData else { return nil }
        var value = (try? JSONDecoder().decode(State.self, from: data))
            ?? State(startedAt: profile.createdAt, checkedAt: profile.createdAt, needsClinicalAdvice: true)
        // A deleted/discarded outing cannot advance recovery, and must not leave the athlete
        // unable to attempt another short outing.
        if let id = value.firstOutingID, let context = profile.modelContext {
            let query = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == id })
            if (try? context.fetchCount(query)) == 0 { value.firstOutingID = nil; value.firstOutingEndedAt = nil }
        }
        return value
    }
    static func isRestricted(in context: ModelContext) -> Bool {
        ((try? context.fetch(FetchDescriptor<UserProfile>())) ?? []).contains { state(for: $0) != nil }
    }
    static func state(for plan: TrainingPlan?) -> State? {
        guard let plan, let context = plan.modelContext else { return nil }
        return ((try? context.fetch(FetchDescriptor<UserProfile>())) ?? [])
            .first(where: { $0.plan?.id == plan.id }).flatMap { state(for: $0) }
    }
    static func canStart(_ session: PlannedSession, profile: UserProfile?) -> Bool {
        guard let state = state(for: profile) else { return true }
        return canStart(session, state: state)
    }
    static func canStart(_ session: PlannedSession, state: State, now: Date = Date()) -> Bool {
        guard state.phase != .resting, !PlanCoaching.isFixedDate(session),
              session.discipline == .running || session.discipline == .walking else { return false }
        if state.phase == .firstOuting, state.firstOutingID != nil { return false }
        if state.phase == .building, let latest = state.completedOutings.values.max(),
           now.timeIntervalSince(latest) < 86_400 { return false }
        return true
    }

    /// Only for conflicting copies and undo. An ordered, clean cloud update may legitimately
    /// complete recovery; a user choosing an older plan is never evidence of medical readiness.
    static func preservingRestrictions(_ first: State?, _ second: State?) -> State? {
        guard let first else { return second }
        guard let second else { return first }
        let order: [Phase: Int] = [.resting: 0, .firstOuting: 1, .building: 2]
        var result = order[first.phase, default: 0] <= order[second.phase, default: 0] ? first : second
        result.needsClinicalAdvice = first.needsClinicalAdvice || second.needsClinicalAdvice
        if first.episodeID != second.episodeID {
            result.phase = .resting
            result.firstOutingID = nil; result.firstOutingEndedAt = nil
            result.returnStartedAt = nil; result.completedOutings = [:]
        }
        return result
    }
    static func blocked(_ intent: CoachIntent, profile: UserProfile) -> String? {
        guard state(for: profile) != nil else { return nil }
        switch intent {
        case .pausePlan, .resumePlan, .bumpLoad, .easeWeek, .easeThisWeek, .easePaces:
            return "Your illness return is active. Use the recovery check-in to change it; dates and harder training will not resume on their own."
        default: return nil
        }
    }

    static func save(_ state: State?, profile: UserProfile, in context: ModelContext) throws {
        let record = PlanContinuityRecord.upsert(profileID: profile.id, in: context)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try state.map { try encoder.encode($0) }
        if record.illnessData != data { record.illnessData = data }
    }

    static func pause(profile: UserProfile, kind: Kind = .other, now: Date = Date(), in context: ModelContext) throws {
        try PlanMutation.perform(in: context) {
            guard profile.plan != nil else { throw Failure.noPlan }
            CoachUndo.makeSoleUndoPoint(in: context)
            var value = state(for: profile) ?? State(startedAt: now, checkedAt: now)
            if value.kind == nil { value.kind = kind }
            value.phase = .resting; value.checkedAt = now
            value.firstOutingID = nil; value.firstOutingEndedAt = nil
            value.returnStartedAt = nil; value.completedOutings = [:]
            try save(value, profile: profile, in: context)
            profile.continuity?.trainingEvidenceFrom = now
            retireMissed(profile.plan, before: now)
            profile.plan?.pausedUntil = nil
            profile.plan?.coachingState?.pauseShiftedDates = [:]
        }
    }

    /// Red flags are persisted even when a readiness request cannot proceed, so a later tap on
    /// the generic resume/rebuild actions cannot silently bypass the need for medical advice.
    static func checkIn(_ answers: Readiness, profile: UserProfile, now: Date = Date(),
                        in context: ModelContext) throws {
        if answers.concerningSymptoms {
            try PlanMutation.perform(in: context) {
                CoachUndo.makeSoleUndoPoint(in: context)
                var value = state(for: profile) ?? State(startedAt: now, checkedAt: now)
                value.phase = .resting; value.needsClinicalAdvice = true; value.checkedAt = now
                value.firstOutingID = nil; value.firstOutingEndedAt = nil
                value.returnStartedAt = nil; value.completedOutings = [:]
                try save(value, profile: profile, in: context)
                profile.continuity?.trainingEvidenceFrom = now
            }
            throw Failure.medicalAdvice
        }
        guard var value = state(for: profile) else { throw Failure.noPlan }
        // Prolonged illness is routed to a professional; elapsed time is never automatic clearance.
        let prolonged = value.phase == .resting && now.timeIntervalSince(value.startedAt) >= 7 * 86_400
        let otherIllness = value.phase == .resting && value.kind != .respiratory
        guard !(value.needsClinicalAdvice || prolonged || otherIllness) || answers.clinicianAdvisedReturn else { throw Failure.medicalAdvice }
        guard answers.improving, answers.feverFreeWithoutMedicineFor24Hours,
              answers.dailyActivitiesComfortable else { throw Failure.notReady }
        if value.phase != .resting, !answers.exerciseWellTolerated { throw Failure.waitForResponse }
        let workouts = try context.fetch(FetchDescriptor<Workout>())
        let evidence = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id.uuidString, $0) })
        try PlanMutation.perform(in: context) {
            CoachUndo.makeSoleUndoPoint(in: context)
            value.checkedAt = now
            switch value.phase {
            case .resting:
                value.phase = .firstOuting; value.firstOutingID = nil; value.firstOutingEndedAt = nil
                value.needsClinicalAdvice = false
                retireMissed(profile.plan, before: now)
            case .firstOuting:
                guard let id = value.firstOutingID, let workout = evidence[id.uuidString],
                      qualifies(workout, phase: .firstOuting, since: value.startedAt, now: now),
                      let ended = value.firstOutingEndedAt, now.timeIntervalSince(ended) >= 86_400 else {
                    throw Failure.waitForResponse
                }
                value.phase = .building; value.returnStartedAt = now
            case .building:
                let realOutings = value.completedOutings.filter { key, end in
                    guard let workout = evidence[key], now.timeIntervalSince(end) >= 86_400 else { return false }
                    return qualifies(workout, phase: .building, since: value.returnStartedAt ?? now, now: now)
                }
                let distinctDays = Set(realOutings.values.map { Calendar.current.startOfDay(for: $0) })
                guard let began = value.returnStartedAt, now.timeIntervalSince(began) >= 7 * 86_400,
                      distinctDays.count >= 2 else { throw Failure.moreEasyTraining }
                restorePrescriptions(value, plan: profile.plan)
                try save(nil, profile: profile, in: context)
                let cutoff = now.addingTimeInterval(-14 * 86_400)
                let runs = try context.fetch(FetchDescriptor<Workout>()).filter {
                    $0.type.discipline == .running && $0.startedAt >= cutoff && $0.startedAt <= now
                        && $0.id != ActiveWorkoutMarker.pendingID
                }
                let weekly = runs.reduce(0.0) { $0 + max(0, $1.gps?.distanceM ?? 0) } / 2
                profile.weeklyRunVolumeM = min(profile.weeklyRunVolumeM ?? weekly, weekly)
                let longest = runs.map { max(0, $0.gps?.distanceM ?? 0) }.max() ?? 0
                profile.longestRunM = min(profile.longestRunM ?? longest, longest)
                if profile.plan?.isSelfCoached != true {
                    _ = try PlanService.stageRegenerate(for: profile, startDate: now, recoveryWeeks: 1, in: context)
                }
                return
            }
            try save(value, profile: profile, in: context)
        }
    }

    private static func qualifies(_ workout: Workout, phase: Phase, since: Date, now: Date) -> Bool {
        (workout.type == .run || workout.type == .walk)
            && workout.durationS.isFinite && workout.elapsedS.isFinite
            && workout.durationS >= 5 * 60 && workout.durationS <= (phase == .firstOuting ? 16 : 31) * 60
            && (workout.perceivedEffort ?? 0) <= 4
            && workout.startedAt >= since && workout.id != ActiveWorkoutMarker.pendingID
            && workout.startedAt.addingTimeInterval(max(workout.durationS, workout.elapsedS)) <= now.addingTimeInterval(60)
    }

    static func record(_ workout: Workout, profile: UserProfile?, now: Date = Date(), in context: ModelContext) {
        guard let profile, var value = state(for: profile), value.phase != .resting,
              qualifies(workout, phase: value.phase, since: value.checkedAt, now: now) else { return }
        _ = PlanMutation.attempt(in: context, fallback: false) {
            let end = workout.startedAt.addingTimeInterval(max(workout.durationS, workout.elapsedS))
            if let id = value.firstOutingID {
                let query = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == id })
                if try context.fetchCount(query) == 0 { value.firstOutingID = nil; value.firstOutingEndedAt = nil }
            }
            if value.phase == .firstOuting, value.firstOutingID == nil {
                value.firstOutingID = workout.id; value.firstOutingEndedAt = end
            } else if value.phase == .building {
                if let latest = value.completedOutings.values.max(),
                   workout.startedAt.timeIntervalSince(latest) < 86_400 { return false }
                value.completedOutings[workout.id.uuidString] = end
            }
            try save(value, profile: profile, in: context)
            return true
        }
    }

    static func retireMissed(_ plan: TrainingPlan?, before today: Date) {
        let day = Calendar.current.startOfDay(for: today)
        for session in plan?.sessions ?? [] where session.date < day && session.completedWorkout == nil
            && (session.status == .planned || session.status == .moved) && !PlanCoaching.isFixedDate(session) {
            session.status = .missed
            session.rationale = "Resting through illness. This session does not need to be made up."
        }
    }
    private static func restorePrescriptions(_ value: State, plan: TrainingPlan?) {
        for session in plan?.sessions ?? [] where session.completedWorkout == nil
            && (session.status == .planned || session.status == .moved) {
            let key = session.id.uuidString
            if value.applied[key] == Prescription(session) { value.originals[key]?.apply(to: session) }
        }
    }

    /// Runs inside the same save boundary as rebuilds, settings, library changes and coaching.
    /// Repeated saves do not compound reductions; independent prescription edits become the new
    /// envelope. Race dates and completed history are never rewritten.
    static func enforce(in context: ModelContext, now: Date = Date()) throws {
        guard context.container.schema.entities.contains(where: { $0.name == "PlanContinuityRecord" }) else { return }
        for profile in try context.fetch(FetchDescriptor<UserProfile>()) {
            guard var value = state(for: profile), let plan = profile.plan else { continue }
            retireMissed(plan, before: now)
            guard value.phase != .resting else { continue }
            let open = plan.sessions.filter { $0.completedWorkout == nil && ($0.status == .planned || $0.status == .moved) }
            let ids = Set(open.map { $0.id.uuidString })
            value.originals = value.originals.filter { ids.contains($0.key) }
            value.applied = value.applied.filter { ids.contains($0.key) }
            var changed = false
            for session in open where !PlanCoaching.isFixedDate(session)
                && (session.discipline == .running || session.discipline == .walking) {
                let key = session.id.uuidString, current = Prescription(session)
                if value.originals[key] == nil || value.applied[key] != current { value.originals[key] = current }
                guard let original = value.originals[key] else { continue }
                original.apply(to: session)
                let pace = max(original.pace ?? 0, PlanEngine.pace(.recovery, p5k: plan.p5kSPerKm))
                let plannedSeconds = original.duration ?? ((original.distance ?? 0) / 1_000 * pace)
                guard plannedSeconds.isFinite, plannedSeconds > 0, pace.isFinite, pace > 0 else { continue }
                let cap = value.phase == .firstOuting ? 15.0 * 60 : min(30.0 * 60, plannedSeconds * 0.7)
                let seconds = min(plannedSeconds, cap)
                session.runType = .recovery; session.intervals = nil
                session.targetDurationS = seconds
                session.targetDistanceM = min(original.distance ?? .greatestFiniteMagnitude, seconds / pace * 1_000)
                session.targetPaceSPerKm = pace
                session.rationale = value.phase == .firstOuting
                    ? "A short easy walk or jog. Stop if symptoms return or effort feels unusual. Check how you feel during, after and the following day."
                    : "Build back gently at conversational effort. Stop and check in if symptoms return. Hard training waits for your next check-in."
                value.applied[key] = Prescription(session)
                changed = changed || current != Prescription(session)
            }
            try save(value, profile: profile, in: context)
            if changed { _ = try RunningPlanBackfill.prepareAfterLegacyPlanMutation(in: context, now: now) }
        }
    }
}
