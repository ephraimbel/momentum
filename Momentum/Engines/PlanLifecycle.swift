import Foundation

// The plan lifecycle, pure (2026-09-07, docs/PLAN-AND-FUEL-UPGRADE.md §3.2).
//
// The current plan is `UserProfile.plan` and nothing else. Everything that is not the current plan
// lives on the shelf as a `PlanShelfRecord` holding a `PlanBlueprint` (inputs, never sessions) and
// a cached `PlanPreview`. These types carry no SwiftData; `PlanLifecycleService` is the only
// writer, and every rule that decides what happens on a date lives here so it can be pinned.

/// Where a shelved plan sits. A draft never becomes anything else on its own.
enum PlanShelfStatus: String, Codable, CaseIterable, Sendable {
    case draft, upcoming, completed, incomplete

    var label: String {
        switch self {
        case .draft: "Draft"
        case .upcoming: "Upcoming"
        case .completed: "Completed"
        case .incomplete: "Incomplete"
        }
    }

    var isPrevious: Bool { self == .completed || self == .incomplete }
}

/// The inputs a plan is built from, as the athlete chose them: what the generator reads that
/// belongs to the plan rather than to the athlete's body. Reading one from the profile and writing
/// it back are the two halves of the same mapping, so a draft activates as exactly what it previewed.
struct PlanBlueprint: Codable, Equatable, Sendable {
    var name: String = ""
    var goal: Goal = .generalFitness
    /// Strength-for-runners days in the week. Running is always in.
    var includesStrength: Bool = false
    var raceDistanceM: Double?
    var raceDate: Date?
    var goalFinishTimeS: Double?
    var daysPerWeek: Int = 3
    /// Calendar weekdays (1 = Sunday … 7 = Saturday). Empty lets the coach spread the week.
    var preferredDays: [Int] = []
    var sessionMinutes: Int = 45
    var equipment: Equipment = .fullGym
    var intensity: PlanIntensity = .balanced
    /// The athlete's weekly-mileage ceiling (meters); nil lets the goal set the peak.
    var targetWeeklyRunVolumeM: Double?
    var hybridPriority: HybridPriority?
    var strengthSplit: StrengthSplitStyle = .coach
    var muscleFocus: [MuscleGroup] = []
    /// Declared current fitness. The generator prefers logged Momentum runs; these are the fallback
    /// and what the builder shows as "where you are".
    var weeklyRunVolumeM: Double?
    var longestRunM: Double?
    var runningExperience: ExperienceLevel = .some
    var liftingExperience: ExperienceLevel = .some

    init() {}

    var isRace: Bool { goal == .raceDistance && (raceDistanceM ?? 0) > 0 }

    /// A strength goal implies lifting, the same guard `PlanService.stageRebuild` applies.
    var lifts: Bool { includesStrength || goal == .getStronger || goal == .buildMuscle }

    /// The race preset, when this is a race plan.
    var raceDistance: RaceDistance? {
        guard isRace, let m = raceDistanceM else { return nil }
        return RaceDistance.nearest(toMeters: m)
    }

    /// The plan's headline when the athlete has not named it: the race, else the goal.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let race = raceDistance {
            if let time = goalFinishTimeS { return "\(PlanFeasibility.hms(time)) \(race.label)" }
            return race.label
        }
        return goal.planLabel
    }

    /// One quiet line of what the plan is for. Under an unnamed plan the title already IS the
    /// goal's label, so the line steps down to the goal's subtitle rather than repeating itself.
    func goalLine(calendar: Calendar = .current) -> String {
        if let race = raceDistance {
            var parts = [race.label]
            if let date = raceDate { parts.append(date.formatted(.dateTime.day().month(.abbreviated).year())) }
            if let time = goalFinishTimeS { parts.append("goal \(PlanFeasibility.hms(time))") }
            return parts.joined(separator: " · ")
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? goal.planSubtitle : goal.planLabel
    }

    /// "4 runs + 2 lifts a week" without claiming a split the engine has not made yet.
    var frequencyLine: String {
        let days = daysPerWeek
        return lifts ? "\(days) days a week, running and strength" : "\(days) runs a week"
    }
}

/// What a plan looks like before it exists: the commitment, made legible. Built from the same
/// generator output the activation will persist, so the card and the plan can never disagree.
struct PlanPreview: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable, Identifiable {
        /// Calendar weekday (1 = Sunday … 7 = Saturday).
        var weekday: Int
        var title: String
        var detail: String?
        var isStrength: Bool
        var isLong: Bool
        var isQuality: Bool
        var id: String { "\(weekday)-\(title)-\(detail ?? "")" }
    }
    struct PhaseSpan: Codable, Equatable, Sendable, Identifiable {
        var phase: PlanPhase
        var weeks: Int
        var id: String { "\(phase.rawValue)-\(weeks)" }
    }
    struct Outlook: Codable, Equatable, Sendable {
        var verdict: String
        var headline: String
        var detail: String
        var options: [String]
        var realisticFinishS: Double?
        var isTooShort: Bool { verdict == PlanFeasibility.Verdict.tooShort.rawValue }
    }

    var weeks: Int
    var startDate: Date
    var endDate: Date
    var runsPerWeek: Int
    var liftsPerWeek: Int
    var typicalWeek: [Day]
    /// Time the typical week asks for, seconds.
    var weeklyTimeS: Double
    var firstWeekM: Double
    var peakWeekM: Double
    /// 1-based, for "week 9 of 12".
    var peakWeekNumber: Int
    var longestRunM: Double
    var phases: [PhaseSpan]
    var outlook: Outlook?
    var plannedSessions: Int
    /// Previous plans only: how many of the planned sessions were completed.
    var completedSessions: Int?

    /// Weeks are the unit of a plan; days would over-promise on a week that has not been placed.
    var durationLine: String {
        weeks == 1 ? "1 week" : "\(weeks) weeks"
    }

    // MARK: - From a generated plan

    static func build(generated: GeneratedPlan, inputs: PlanInputs, startDate: Date,
                      feasibility: PlanFeasibility?, calendar: Calendar = .current) -> PlanPreview {
        let weeks = generated.weeks
        let anchorWeekday = inputs.anchorWeekday ?? calendar.component(.weekday, from: startDate)
        let start = calendar.startOfDay(for: startDate)
        let lastWeekEnd = calendar.date(byAdding: .day, value: max(0, weeks.count * 7 - 1), to: start) ?? start
        let end = inputs.raceDate.map { min(calendar.startOfDay(for: $0), lastWeekEnd) } ?? lastWeekEnd

        let typical = typicalWeek(weeks)
        let unit = inputs.distanceUnit
        let days: [Day] = typical?.sessions.sorted { $0.dayOffset < $1.dayOffset }.map { s in
            let weekday = ((anchorWeekday - 1 + s.dayOffset) % 7) + 1
            if s.discipline == .strength {
                return Day(weekday: weekday, title: s.strengthLabel ?? "Strength",
                           detail: s.strengthTargets.isEmpty ? nil : "\(s.strengthTargets.count) exercises",
                           isStrength: true, isLong: false, isQuality: false)
            }
            let title = s.runType?.planTitle ?? "Run"
            var detail: String?
            if let m = s.targetDistanceM, m > 0 { detail = Formatters.distance(meters: m, unit: unit) }
            else if let d = s.targetDurationS, d > 0 { detail = Formatters.compactDuration(s: d) }
            return Day(weekday: weekday, title: title, detail: detail, isStrength: false,
                       isLong: s.runType == .long, isQuality: s.runType?.isQuality ?? false)
        } ?? []

        let runsPerWeek = typical.map { w in
            w.sessions.filter { $0.discipline != .strength && $0.runType != .race }.count
        } ?? 0
        let liftsPerWeek = typical.map { w in w.sessions.filter { $0.discipline == .strength }.count } ?? 0
        let weeklyTimeS = typical.map { w in
            w.sessions.reduce(0.0) { acc, s in
                if s.discipline == .strength { return acc + Double(inputs.sessionMinutes) * 60 }
                return acc + (FuelingGuide.estimatedDurationS(distanceM: s.targetDistanceM,
                                                             paceSPerKm: s.targetPaceSPerKm,
                                                             durationS: s.targetDurationS) ?? 0)
            }
        } ?? 0

        let volumes = weeks.map(\.trainingVolumeM)
        let peakIndex = volumes.indices.max { volumes[$0] < volumes[$1] } ?? 0
        let longest = weeks.flatMap(\.sessions)
            .filter { $0.discipline != .strength && $0.runType != .race }
            .compactMap(\.targetDistanceM).max() ?? 0

        var phases: [PhaseSpan] = []
        for week in weeks {
            if let last = phases.indices.last, phases[last].phase == week.phase {
                phases[last].weeks += 1
            } else {
                phases.append(PhaseSpan(phase: week.phase, weeks: 1))
            }
        }

        let outlook = feasibility.map {
            Outlook(verdict: $0.verdict.rawValue, headline: $0.headline, detail: $0.detail,
                    options: $0.options, realisticFinishS: $0.realisticFinishS)
        }

        return PlanPreview(
            weeks: weeks.count, startDate: start, endDate: end,
            runsPerWeek: runsPerWeek, liftsPerWeek: liftsPerWeek, typicalWeek: days,
            weeklyTimeS: weeklyTimeS,
            firstWeekM: volumes.first ?? 0, peakWeekM: volumes.max() ?? 0, peakWeekNumber: peakIndex + 1,
            longestRunM: longest, phases: phases, outlook: outlook,
            plannedSessions: weeks.reduce(0) { $0 + $1.sessions.count }, completedSessions: nil)
    }

    /// The week the plan spends most of its time in: the first build week that is not a down week,
    /// else the fullest week there is. A one-week plan is its own typical week.
    private static func typicalWeek(_ weeks: [GeneratedWeek]) -> GeneratedWeek? {
        if let build = weeks.first(where: { $0.phase == .build && !$0.isDeload && !$0.isTaper }) { return build }
        if let base = weeks.first(where: { !$0.isDeload && !$0.isTaper && $0.phase != .recovery }) { return base }
        return weeks.max { $0.sessions.count < $1.sessions.count }
    }

    // MARK: - From a retired plan's snapshot

    /// The look-back preview for a previous plan, read off its final state. Sessions completed are
    /// counted from the ledger the plan kept; the Workout rows themselves are never consulted.
    static func build(snapshot: CoachUndo.Snapshot.PlanState, blueprint: PlanBlueprint,
                      distanceUnit: DistanceUnit, calendar: Calendar = .current) -> PlanPreview {
        let sessions = snapshot.sessions
        let dates = sessions.map(\.date)
        let start = calendar.startOfDay(for: dates.min() ?? snapshot.createdAt)
        let end = calendar.startOfDay(for: snapshot.raceDate ?? dates.max() ?? start)
        let weekCount = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) / 7 + 1)
        let byWeek = Dictionary(grouping: sessions) {
            (calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: $0.date)).day ?? 0) / 7
        }
        func volume(_ week: [CoachUndo.Snapshot.SessionState]) -> Double {
            week.filter { $0.discipline != Discipline.strength.rawValue && $0.runType != RunType.race.rawValue }
                .compactMap(\.targetDistanceM).reduce(0, +)
        }
        let volumes = (0..<weekCount).map { volume(byWeek[$0] ?? []) }
        let peakIndex = volumes.indices.max { volumes[$0] < volumes[$1] } ?? 0
        let typical = byWeek.values.max { $0.count < $1.count } ?? []
        let runs = typical.filter { $0.discipline != Discipline.strength.rawValue && $0.runType != RunType.race.rawValue }.count
        let lifts = typical.filter { $0.discipline == Discipline.strength.rawValue }.count
        let longest = sessions
            .filter { $0.discipline != Discipline.strength.rawValue && $0.runType != RunType.race.rawValue }
            .compactMap(\.targetDistanceM).max() ?? 0
        var phases: [PhaseSpan] = []
        for raw in snapshot.weekPhases {
            guard let phase = PlanPhase(rawValue: raw) else { continue }
            if let last = phases.indices.last, phases[last].phase == phase { phases[last].weeks += 1 }
            else { phases.append(PhaseSpan(phase: phase, weeks: 1)) }
        }
        let done = sessions.filter { $0.status == SessionStatus.completed.rawValue }.count
        return PlanPreview(
            weeks: weekCount, startDate: start, endDate: end,
            runsPerWeek: runs, liftsPerWeek: lifts, typicalWeek: [],
            weeklyTimeS: 0, firstWeekM: volumes.first ?? 0, peakWeekM: volumes.max() ?? 0,
            peakWeekNumber: peakIndex + 1, longestRunM: longest, phases: phases, outlook: nil,
            plannedSessions: sessions.count, completedSessions: done)
    }
}

/// The date rules. Every "what happens when" of the shelf is one of these functions.
enum PlanLifecycle {
    /// The current plan, reduced to what the calendar needs to know about it.
    struct Span: Equatable, Sendable {
        var start: Date
        /// The last planned day (race day for a race plan). nil for an empty self-coached plan.
        var end: Date?
        var raceDate: Date?
        /// Dates of sessions still open (planned or moved).
        var openSessionDates: [Date]
    }

    /// What starting another plan on a date would do to the current one.
    struct Overlap: Equatable, Sendable {
        var currentEnd: Date
        /// Whole weeks of the current plan that would be cut, at least one.
        var weeksCut: Int
        var sessionsCut: Int
        var cutsGoalRace: Bool
        var raceDate: Date?
        /// The first day after the current plan ends; the "start after" alternative.
        var nextFreeStart: Date
    }

    /// nil when the current plan is over by `proposedStart` (or there is no current plan);
    /// otherwise the cut, so the athlete decides with the affected dates in front of them.
    static func overlap(current: Span?, proposedStart: Date, calendar: Calendar = .current) -> Overlap? {
        guard let current, let end = current.end else { return nil }
        let start = calendar.startOfDay(for: proposedStart)
        let endDay = calendar.startOfDay(for: end)
        guard endDay >= start else { return nil }
        let daysCut = (calendar.dateComponents([.day], from: start, to: endDay).day ?? 0) + 1
        let sessionsCut = current.openSessionDates.filter { calendar.startOfDay(for: $0) >= start }.count
        let cutsRace = current.raceDate.map { calendar.startOfDay(for: $0) >= start } ?? false
        let nextFree = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        return Overlap(currentEnd: endDay, weeksCut: max(1, Int((Double(daysCut) / 7).rounded(.up))),
                       sessionsCut: sessionsCut, cutsGoalRace: cutsRace, raceDate: current.raceDate,
                       nextFreeStart: nextFree)
    }

    /// A plan that reached its own end is completed; one replaced with open weeks left is incomplete.
    static func retirementStatus(_ span: Span?, at date: Date, calendar: Calendar = .current) -> PlanShelfStatus {
        guard let span, let end = span.end else { return .completed }
        return calendar.startOfDay(for: end) < calendar.startOfDay(for: date) ? .completed : .incomplete
    }

    /// An upcoming plan is due on its scheduled day and stays due until it is activated.
    static func isDue(scheduledStart: Date, today: Date, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: scheduledStart) <= calendar.startOfDay(for: today)
    }

    /// Among several due plans the earliest scheduled one starts; the others go back to drafts.
    static func firstDue<ID: Hashable>(_ candidates: [(id: ID, scheduledStart: Date)], today: Date,
                                       calendar: Calendar = .current) -> ID? {
        candidates.filter { isDue(scheduledStart: $0.scheduledStart, today: today, calendar: calendar) }
            .sorted { $0.scheduledStart < $1.scheduledStart }
            .first?.id
    }

    /// An activated plan starts the day it is activated, never backdated: a plan opens with a run
    /// the athlete can go and do, and a plan that started last Tuesday would open with three
    /// misses. Evening activations start tomorrow, the same rule as a brand-new plan.
    static func activationStart(now: Date, calendar: Calendar = .current) -> Date {
        PlanService.firstPlanStart(now: now, calendar: calendar)
    }

    /// A schedule date must be tomorrow or later; today is "start now".
    static func canSchedule(_ date: Date, today: Date, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: date) > calendar.startOfDay(for: today)
    }

    /// "Week 4 of 12" for the current plan card.
    struct Progress: Equatable, Sendable {
        var weekNumber: Int
        var weeks: Int
        var sessionsDone: Int
        var sessionsPlanned: Int
        var fraction: Double { sessionsPlanned == 0 ? 0 : Double(sessionsDone) / Double(sessionsPlanned) }
    }

    static func progress(start: Date, weeks: Int, sessionStatuses: [SessionStatus], today: Date,
                         calendar: Calendar = .current) -> Progress {
        let startDay = calendar.startOfDay(for: start)
        let days = calendar.dateComponents([.day], from: startDay, to: calendar.startOfDay(for: today)).day ?? 0
        let week = min(max(1, days / 7 + 1), max(1, weeks))
        return Progress(weekNumber: week, weeks: max(1, weeks),
                        sessionsDone: sessionStatuses.filter { $0 == .completed }.count,
                        sessionsPlanned: sessionStatuses.count)
    }

    /// Days until a scheduled start, for "Starts in 6 days" / "Starts tomorrow" / "Starts today".
    static func startsLine(scheduledStart: Date, today: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today),
                                           to: calendar.startOfDay(for: scheduledStart)).day ?? 0
        switch days {
        case ..<0: return "Was due \(scheduledStart.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))"
        case 0: return "Starts today"
        case 1: return "Starts tomorrow"
        case 2...13: return "Starts in \(days) days"
        default: return "Starts \(scheduledStart.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }
}
