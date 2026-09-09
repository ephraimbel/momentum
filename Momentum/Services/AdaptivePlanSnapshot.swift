import Foundation
import SwiftData

extension PlanCloudSnapshot {
    struct AdaptiveState: Codable {
        var planID: UUID
        var initializedAt: Date
        var timeZoneID: String
        var firstWeekday: Int
        var minimumDays: Int
        var lastWeekKey: String
        var lastWeekStart: Date
        var baselineData: Data? = nil
        var reviewsData: Data
        var requiresRecoveryCheckin: Bool
        init(_ r: AdaptivePlanRecord) {
            planID = r.id; initializedAt = r.initializedAt; timeZoneID = r.timeZoneID
            firstWeekday = r.firstWeekday; minimumDays = r.minimumDaysInFirstWeek
            lastWeekKey = r.lastWeekKey; lastWeekStart = r.lastWeekStart
            baselineData = r.baselineData
            reviewsData = r.reviewsData; requiresRecoveryCheckin = r.requiresRecoveryCheckin
        }
        func restore(profile: UserProfile, in context: ModelContext) throws {
            guard profile.plan?.id == planID, (1...7).contains(firstWeekday),
                  (1...7).contains(minimumDays), TimeZone(identifier: timeZoneID) != nil,
                  reviewsData.count < 1_000_000 else { throw Failure.invalidSnapshot }
            _ = try JSONDecoder().decode([AdaptivePlanRecord.Review].self, from: reviewsData)
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: timeZoneID)!; c.firstWeekday = firstWeekday
            c.minimumDaysInFirstWeek = minimumDays
            let row = AdaptivePlanRecord.fetch(planID: planID, in: context)
                ?? AdaptivePlanRecord(planID: planID, profileID: profile.id, now: initializedAt, calendar: c)
            if row.modelContext == nil { context.insert(row) }
            // A cloud conflict cannot remove a local safety hold or unfinalize a decided week.
            row.requiresRecoveryCheckin = row.requiresRecoveryCheckin || requiresRecoveryCheckin
            // Restore the selected receipt WITH its selected prescription as one coherent snapshot.
            row.timeZoneID = timeZoneID; row.firstWeekday = firstWeekday
            row.minimumDaysInFirstWeek = minimumDays
            row.lastWeekStart = lastWeekStart; row.lastWeekKey = lastWeekKey
            row.reviewsData = reviewsData
            row.baselineData = baselineData ?? Data("[]".utf8)
        }
    }
    struct RecoveryFeedback: Codable {
        var id: UUID
        var submittedAt: Date
        var recovery: Int?
        var pain: Bool?
        var couldContinue: Bool?
        var illness: Bool?
        var launchedSessionID: UUID?
        var plannedDistanceM: Double?
        var plannedDurationS: Double?
        var plannedPaceSPerKm: Double?
        var plannedRunType: String?
        init(_ r: WorkoutFeedbackRecord) {
            id = r.id; submittedAt = r.submittedAt; recovery = r.recovery
            pain = r.pain; couldContinue = r.couldContinue; illness = r.illness
            launchedSessionID = r.launchedSessionID; plannedDistanceM = r.plannedDistanceM
            plannedDurationS = r.plannedDurationS
            plannedPaceSPerKm = r.plannedPaceSPerKm; plannedRunType = r.plannedRunType
        }
        func restore(in context: ModelContext) {
            let old = WorkoutFeedbackRecord.fetch(workoutID: id, in: context)
            if let old, old.submittedAt > submittedAt { return }
            let r = old ?? WorkoutFeedbackRecord(workoutID: id, now: submittedAt)
            if old == nil { context.insert(r) }
            r.submittedAt = submittedAt; r.recovery = recovery
            r.pain = pain; r.couldContinue = couldContinue; r.illness = illness
            r.launchedSessionID = launchedSessionID; r.plannedDistanceM = plannedDistanceM
            r.plannedDurationS = plannedDurationS
            r.plannedPaceSPerKm = plannedPaceSPerKm; r.plannedRunType = plannedRunType
        }
    }
}
