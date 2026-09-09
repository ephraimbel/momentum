import Foundation
import SwiftData

/// V10 scalar-ID sidecars. No released plan, workout or profile entity changes shape.
@Model
final class AdaptivePlanRecord {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var initializedAt: Date
    var timeZoneID: String
    var firstWeekday: Int
    var minimumDaysInFirstWeek: Int
    var lastWeekKey: String
    var lastWeekStart: Date
    var baselineData: Data = Data("[]".utf8)
    var reviewsData: Data = Data("[]".utf8)
    var introducedAt: Date?
    var requiresRecoveryCheckin: Bool = false

    init(planID: UUID, profileID: UUID, now: Date, calendar: Calendar) {
        id = planID; self.profileID = profileID; initializedAt = now
        timeZoneID = calendar.timeZone.identifier
        firstWeekday = calendar.firstWeekday
        minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        lastWeekKey = AdaptiveTrainingWeek.key(now, calendar: calendar)
        lastWeekStart = AdaptiveTrainingWeek.week(containing: now, calendar: calendar).start
    }
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        c.firstWeekday = firstWeekday; c.minimumDaysInFirstWeek = minimumDaysInFirstWeek
        return c
    }
    struct Baseline: Codable {
        var id: UUID
        var date: Date
        var distanceM: Double
    }
    var baseline: [Baseline] {
        get { (try? JSONDecoder().decode([Baseline].self, from: baselineData)) ?? [] }
        set { baselineData = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8) }
    }
    struct Review: Codable, Identifiable {
        var id: String
        var weekStart: Date
        var createdAt: Date
        var summary: String
        var explanation: String
        var reason: String
        var beforeM: Double
        var afterM: Double
        var changes: [String]
        var evidence: AdaptiveTrainingWeek.Evidence
        var viewedAt: Date?
        var goalOutlook: String? = nil
        var focus: String? = nil
    }
    var reviews: [Review] {
        get { (try? JSONDecoder().decode([Review].self, from: reviewsData)) ?? [] }
        set { reviewsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    static func fetch(planID: UUID, in context: ModelContext) -> AdaptivePlanRecord? {
        guard context.container.schema.entities.contains(where: { $0.name == "AdaptivePlanRecord" }) else { return nil }
        var q = FetchDescriptor<AdaptivePlanRecord>(predicate: #Predicate { $0.id == planID })
        q.fetchLimit = 1
        return (try? context.fetch(q))?.first
    }
}

@Model
final class WorkoutFeedbackRecord {
    @Attribute(.unique) var id: UUID
    var submittedAt: Date
    var recovery: Int? // 1 drained, 2 okay, 3 recovered
    var pain: Bool?
    var couldContinue: Bool?
    var illness: Bool?
    var note: String
    var launchedSessionID: UUID?
    var plannedDistanceM: Double?
    var plannedDurationS: Double?
    var plannedPaceSPerKm: Double?
    var plannedRunType: String?
    init(workoutID: UUID, now: Date = Date()) {
        id = workoutID; submittedAt = now; note = ""
    }
    static func fetch(workoutID: UUID, in context: ModelContext) -> WorkoutFeedbackRecord? {
        guard context.container.schema.entities.contains(where: { $0.name == "WorkoutFeedbackRecord" }) else { return nil }
        var q = FetchDescriptor<WorkoutFeedbackRecord>(predicate: #Predicate { $0.id == workoutID })
        q.fetchLimit = 1
        return (try? context.fetch(q))?.first
    }
}

extension TrainingPlan {
    var adaptiveState: AdaptivePlanRecord? {
        modelContext.flatMap { AdaptivePlanRecord.fetch(planID: id, in: $0) }
    }
}
