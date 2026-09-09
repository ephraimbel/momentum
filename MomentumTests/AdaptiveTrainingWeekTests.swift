import Foundation
import SwiftData
import Testing
@testable import Momentum

@MainActor
struct AdaptiveTrainingWeekTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4
        return c
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func container() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    @Test func progressionIsBoundedByActualTrainingAndTaper() {
        var e = AdaptiveTrainingWeek.Evidence()
        e.prescribedRuns = 3; e.completedRuns = 3; e.recordedRuns = 3
        e.plannedM = 10_000; e.actualM = 10_000; e.recentWeeklyM = 10_000
        #expect(AdaptiveTrainingWeek.decide(e, frameworkM: 14_000, alreadyAdapted: false).maximumM == 10_500)
        #expect(AdaptiveTrainingWeek.decide(e, frameworkM: 6_000, alreadyAdapted: false).maximumM == 6_000)
        e.poorRecovery = true
        let eased = AdaptiveTrainingWeek.decide(e, frameworkM: 14_000, alreadyAdapted: false)
        #expect(eased.maximumM == 8_500 && eased.easyOnly)
    }

    @Test func adaptiveAnalyticsCarriesTypedContextWithoutFeedbackText() {
        let event = AnalyticsEvent.adaptive(action: "post_workout_feedback_submitted", week: "2026-37",
            reason: "checkin", goal: .generalFitness, workout: .run, status: .completed)
        #expect(event.parameters["goal_type"] == Goal.generalFitness.rawValue)
        #expect(event.parameters["workout_type"] == "run" && event.parameters["completion_status"] == "completed")
        #expect(event.parameters.keys.sorted() == ["completion_status", "goal_type", "plan_week", "reason", "workout_type"])
    }

    @Test func painOverridesWeeklyThrottle() {
        var e = AdaptiveTrainingWeek.Evidence(); e.pain = true
        let d = AdaptiveTrainingWeek.decide(e, frameworkM: 20_000, alreadyAdapted: true)
        #expect(d.rest && d.maximumM == 0)
    }

    @Test func manualCompletionDoesNotInventMileage() {
        var e = AdaptiveTrainingWeek.Evidence()
        e.prescribedRuns = 3; e.completedRuns = 3; e.plannedM = 6_000
        let d = AdaptiveTrainingWeek.decide(e, frameworkM: 8_000, alreadyAdapted: false)
        #expect(d.maximumM == 6_000 && d.easyOnly)
        e.completedRuns = 0
        #expect(AdaptiveTrainingWeek.decide(e, frameworkM: 8_000, alreadyAdapted: false).maximumM == 3_000)
    }

    @Test func minimumNeverAddsLoadOrLeavesHardWalkingIntervals() {
        var s = GeneratedSession(dayOffset: 0, discipline: .running, runType: .intervals,
            targetDistanceM: 800, targetDurationS: 600, intervals: "4 × 200m", isHardRun: true)
        AdaptiveTrainingWeek.normalize(&s)
        #expect(s.discipline == .walking && s.targetDistanceM == 800)
        #expect(!s.isHardRun && s.intervals == nil && s.targetDurationS == 600)
        s.discipline = .running; s.targetDistanceM = AdaptiveTrainingWeek.minimumRunM
        AdaptiveTrainingWeek.normalize(&s)
        #expect(s.discipline == .running)
    }

    @Test func weekBoundaryUsesCalendarIncludingDST() {
        let before = date("2026-03-08T23:00:00Z")
        let after = date("2026-03-09T06:00:00Z")
        #expect(AdaptiveTrainingWeek.key(before, calendar: calendar) != AdaptiveTrainingWeek.key(after, calendar: calendar))
        let interval = AdaptiveTrainingWeek.week(containing: before, calendar: calendar)
        #expect(interval.duration == 167 * 3600)
        #expect(calendar.component(.weekday, from: interval.start) == 2)
    }

    @Test func rolloutPreservesCurrentWeekAndNextWeekIsIdempotent() throws {
        let store = try container(); let c = store.mainContext
        let p = UserProfile(); c.insert(p)
        let plan = TrainingPlan(); c.insert(plan); p.plan = plan
        let start = date("2026-09-07T05:00:00Z"); plan.blockStart = start
        let old = PlannedSession(); old.date = start; old.targetDistanceM = 800
        let next = PlannedSession(); next.date = date("2026-09-14T05:00:00Z"); next.targetDistanceM = 4000
        plan.sessions = [old, next]; try c.save()
        try PlanMutation.perform(in: c) {
            AdaptivePlanService.initialize(plan, profileID: p.id, now: start, in: c, calendar: calendar)
        }
        #expect(old.targetDistanceM == 800 && old.discipline == .running)
        #expect(!AdaptivePlanService.showsDetails(next, plan: plan, now: start, calendar: calendar))
        let now = date("2026-09-14T12:00:00Z")
        #expect(AdaptivePlanService.refresh(profile: p, now: now, in: c))
        #expect(plan.adaptiveState?.reviews.count == 1)
        let distance = next.targetDistanceM
        #expect(AdaptivePlanService.refresh(profile: p, now: now, in: c))
        #expect(plan.adaptiveState?.reviews.count == 1 && next.targetDistanceM == distance)
        #expect(old.status == .missed)
        #expect(next.discipline == .walking) // A zero-record week cannot inflate a short safe dose.
    }

    @Test func feedbackAndSafetyHoldPersistTogether() throws {
        let store = try container(); let c = store.mainContext
        let p = UserProfile(); c.insert(p); let plan = TrainingPlan(); p.plan = plan
        let s = PlannedSession(); s.targetDistanceM = 3000; plan.sessions = [s]
        let w = Workout(); c.insert(w)
        var draft = WorkoutRecoveryDraft(); draft.pain = true; draft.recovery = 1
        draft.persist(for: w); try c.save()
        #expect(WorkoutFeedbackRecord.fetch(workoutID: w.id, in: c)?.pain == true)
        #expect(plan.adaptiveState?.requiresRecoveryCheckin == true)
        #expect(!PlanCoaching.canStartPlannedSession(s, profile: p))
    }

    @Test func failedTransactionRetainsPrescriptionAndNoReview() throws {
        enum Fault: Error { case disk }
        let store = try container(); let c = store.mainContext
        let p = UserProfile(); c.insert(p); let plan = TrainingPlan(); p.plan = plan
        let s = PlannedSession(); s.targetDistanceM = 4000; plan.sessions = [s]; try c.save()
        do {
            try PlanMutation.perform(in: c, commit: { _ in throw Fault.disk }) {
                s.targetDistanceM = 2000
                AdaptivePlanService.initialize(plan, profileID: p.id, now: Date(), in: c)
            }
            Issue.record("Expected the injected save failure")
        } catch {}
        #expect(s.targetDistanceM == 4000)
        #expect(plan.adaptiveState == nil)
    }

    @Test func clearingFeedbackPersistsWithoutErasingAttemptOrSilentlyClearingSafety() throws {
        let store = try container(), c = store.mainContext
        let p = UserProfile(); c.insert(p); let plan = TrainingPlan(); p.plan = plan
        let w = Workout(); c.insert(w)
        var draft = WorkoutRecoveryDraft(); draft.pain = true
        draft.persist(for: w); try c.save()
        let record = try #require(WorkoutFeedbackRecord.fetch(workoutID: w.id, in: c))
        record.plannedDistanceM = 5000; record.plannedDurationS = 1800
        let submitted = record.submittedAt
        draft.persist(for: w)
        #expect(record.submittedAt == submitted)
        draft.pain = nil; draft.persist(for: w); try c.save()
        let fresh = ModelContext(store)
        let restored = try #require(WorkoutFeedbackRecord.fetch(workoutID: w.id, in: fresh))
        #expect(restored.pain == nil && restored.plannedDistanceM == 5000 && restored.plannedDurationS == 1800)
        #expect(plan.adaptiveState?.requiresRecoveryCheckin == true)
    }

    @Test func weeklyReviewNamesOnlyObservedSignalsAndKeepsOldReviewsReadable() throws {
        var e = AdaptiveTrainingWeek.Evidence()
        e.prescribedRuns = 3; e.completedRuns = 3
        #expect(AdaptiveTrainingWeek.observations(e).contains("every planned"))
        #expect(!AdaptiveTrainingWeek.observations(e).contains("heart"))
        e.difficultRuns = 1; e.poorRecovery = true
        let explanation = AdaptiveTrainingWeek.observations(e)
        #expect(explanation.contains("1 run felt") && explanation.contains("recovery"))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        json.removeValue(forKey: "actualDurationS"); json.removeValue(forKey: "aboveEasyHeartRateRuns")
        json.removeValue(forKey: "prolongedHardRuns")
        let old = try JSONDecoder().decode(AdaptiveTrainingWeek.Evidence.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.difficultRuns == 1 && old.actualDurationS == nil)
        let decision = AdaptiveTrainingWeek.decide(e, frameworkM: 5000, alreadyAdapted: false)
        #expect(AdaptiveTrainingWeek.focus(for: .taper, decision: decision).contains("taper"))
    }
}

@MainActor
struct AdaptiveEvidenceTests {
    @Test func uncreditedAttemptsUseOriginalPaceDurationAndHeartRateWithReportedStrain() throws {
        let schema = Schema(PersistenceController.models)
        let store = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let c = store.mainContext
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!; cal.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-09-14T12:00:00Z")!
        let start = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
        let profile = UserProfile(); c.insert(profile)
        let plan = TrainingPlan(); plan.blockStart = start; profile.plan = plan
        AdaptivePlanService.initialize(plan, profileID: profile.id, now: start, in: c, calendar: cal)
        let record = try #require(plan.adaptiveState)
        let w = Workout(); w.startedAt = start; w.type = .trailRun; w.durationS = 2400; w.perceivedEffort = 7
        let gps = GPSDetail(); gps.distanceM = 3000; gps.avgPaceSPerKm = 320; gps.avgHR = 160; w.gps = gps
        c.insert(w)
        let feedback = WorkoutFeedbackRecord(workoutID: w.id)
        feedback.plannedDistanceM = 5000; feedback.plannedPaceSPerKm = 400
        feedback.plannedDurationS = 1800; feedback.plannedRunType = RunType.easy.rawValue
        c.insert(feedback); try c.save()
        let evidence = try AdaptivePlanService.evidence(plan: plan, record: record, now: now, in: c, maxHR: 190, restingHR: 50)
        #expect(evidence.shortenedRuns == 1 && evidence.exceededEffort)
        #expect(evidence.recordedRuns == 1 && evidence.actualM == 3000)
        #expect(evidence.actualDurationS == 2400 && evidence.prolongedHardRuns == 1)
        #expect(evidence.aboveEasyHeartRateRuns == 1 && w.plannedSession == nil)
        w.perceivedEffort = nil
        let unconfirmed = try AdaptivePlanService.evidence(plan: plan, record: record, now: now, in: c, maxHR: 190, restingHR: 50)
        #expect(!unconfirmed.exceededEffort && unconfirmed.prolongedHardRuns == 0)
        #expect(unconfirmed.aboveEasyHeartRateRuns == 1)
        gps.avgHR = nil
        let absent = try AdaptivePlanService.evidence(plan: plan, record: record, now: now, in: c)
        #expect(absent.aboveEasyHeartRateRuns == 0 && !absent.exceededEffort)
        gps.distanceM = .nan
        let invalid = try AdaptivePlanService.evidence(plan: plan, record: record, now: now, in: c)
        #expect(invalid.actualM == 0 && invalid.recentWeeklyM == 0)
    }

    @Test func shortenedAttemptKeepsItsOriginalTargetWithoutFalseCompletion() throws {
        let schema = Schema(PersistenceController.models)
        let store = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let c = store.mainContext
        let profile = UserProfile(); c.insert(profile)
        let plan = TrainingPlan(); profile.plan = plan
        let s = PlannedSession(); s.targetDistanceM = 10000; s.runType = .long; plan.sessions = [s]
        let w = Workout(); w.type = .run; w.durationS = 900
        let gps = GPSDetail(); gps.distanceM = 2000; w.gps = gps; c.insert(w); try c.save()
        let credited = PlanCoaching.creditLaunched(s, with: w, to: plan, in: c)
        #expect(credited == nil && s.status != .completed)
        let attempt = try #require(WorkoutFeedbackRecord.fetch(workoutID: w.id, in: c))
        #expect(attempt.launchedSessionID == s.id && attempt.plannedDistanceM == 10000)
        // Later editing a target cannot rewrite what the athlete actually attempted.
        s.targetDistanceM = 5000; try c.save()
        #expect(attempt.plannedDistanceM == 10000)
    }

    @Test func quietWindowHandlesMidnightAndDisabledWindow() {
        #expect(!NotificationQuietHours.allows(hour: 23, start: 22, end: 6))
        #expect(!NotificationQuietHours.allows(hour: 5, start: 22, end: 6))
        #expect(NotificationQuietHours.allows(hour: 6, start: 22, end: 6))
        #expect(NotificationQuietHours.allows(hour: 23, start: 0, end: 0))
        #expect(!NotificationQuietHours.allows(hour: 13, start: 12, end: 14))
    }
}
