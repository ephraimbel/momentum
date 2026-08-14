import Foundation
import SwiftData
import WidgetKit

/// The app-side half of the Home Screen widget: composes a display-ready `WidgetSnapshot` from the
/// live plan + log and publishes it through the shared App Group. The widget stays a pure renderer;
/// every number and string is decided here, by the same engines the app uses (rules compute).
///
/// Cheap and idempotent — called from Today's appear path; an unchanged snapshot writes nothing
/// and never wakes the widget.
@MainActor
enum WidgetBridge {

    static func publish(profile: UserProfile?, workouts: [Workout],
                        today: Date = Date(), calendar: Calendar = .current,
                        stats: ProfileStats? = nil) {
        let snapshot = build(profile: profile, workouts: workouts, today: today, calendar: calendar,
                             stats: stats)
        guard snapshot != WidgetSnapshot.load() else { return }
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "TodayWidget")
    }

    /// Wipe the published snapshot and wake the widget — the data wipes call this so a reset
    /// athlete's Home Screen doesn't keep glowing with the deleted streak. Safe from any thread
    /// (UserDefaults and WidgetCenter both are).
    nonisolated static func clear() {
        UserDefaults(suiteName: WidgetSnapshot.appGroup)?.removeObject(forKey: WidgetSnapshot.storageKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "TodayWidget")
    }

    /// Pure composition — separated so fixtures can assert on it directly.
    static func build(profile: UserProfile?, workouts: [Workout],
                      today: Date = Date(), calendar: Calendar = .current,
                      stats: ProfileStats? = nil) -> WidgetSnapshot {
        let plan = profile?.plan
        // A caller that already walked the history this pass hands its stats in — the walk is the
        // expensive part of this build, and Today's bootstrap was paying it twice back-to-back.
        let stats = stats ?? ProfileStats(workouts: workouts, plan: plan, calendar: calendar)

        // Today's session — the first still-open one; done when it completed or a workout landed.
        let todays = PlanCoaching.todaySessions(plan, on: today, calendar: calendar)
        let open = todays.first { $0.status != .completed && $0.completedWorkout == nil }
        let session = open ?? todays.first
        let workoutToday = workouts.contains { calendar.isDate($0.startedAt, inSameDayAs: today) }
        let done = workoutToday || (session != nil && open == nil)

        var title: String?
        var hero: String?
        var detail: String?
        if let session {
            (title, hero, detail) = describe(session)
        } else if done {
            // No plan today but the athlete moved anyway — celebrate it, don't call it rest.
            title = "Logged"
            hero = "Done"
            detail = "Nothing was planned. You went anyway."
        }

        return WidgetSnapshot(
            dayStamp: WidgetSnapshot.dayStamp(for: today, calendar: calendar),
            streak: stats.currentStreak,
            sessionTitle: title,
            sessionHero: hero,
            sessionDetail: detail,
            sessionDone: done && session != nil || (session == nil && workoutToday),
            week: weekMarks(plan: plan, workouts: workouts, today: today, calendar: calendar))
    }

    /// Label / hero / detail for a planned session, in display units.
    private static func describe(_ session: PlannedSession) -> (String, String, String?) {
        let title: String
        if session.discipline == .running, let run = session.runType {
            switch run {
            case .easy: title = "Easy run"
            case .long: title = "Long run"
            case .recovery: title = "Recovery run"
            case .freeRun: title = "Run"
            default: title = run.rawValue.capitalized
            }
        } else if session.discipline == .strength {
            title = "Strength"
        } else {
            title = session.discipline.rawValue.capitalized
        }

        var hero: String?
        var detail: String?
        if let d = session.targetDistanceM, d > 0 {
            hero = Formatters.distance(meters: d, unit: .auto)
            if let pace = session.targetPaceSPerKm, pace > 0 {
                detail = "~\(Formatters.pace(secPerKm: pace, unit: .auto))"
            }
        } else if let dur = session.targetDurationS, dur > 0 {
            hero = "\(Int((dur / 60).rounded())) min"
        }
        return (title, hero ?? title, detail)
    }

    /// The ribbon: this calendar week, one mark per day. Done = a logged workout or a completed
    /// session that day (earned fill); planned = an open session; anything else is quiet rest —
    /// including past days with nothing logged (no-shame: the ribbon never marks a miss).
    private static func weekMarks(plan: TrainingPlan?, workouts: [Workout],
                                  today: Date, calendar: Calendar) -> [WidgetSnapshot.DayMark] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today) else { return [] }
        let symbols = calendar.veryShortWeekdaySymbols   // Sunday-first; index by weekday component
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            let weekday = calendar.component(.weekday, from: day)
            let letter = symbols[weekday - 1]

            let sessions = (plan?.sessions ?? []).filter { calendar.isDate($0.date, inSameDayAs: day) }
            let logged = workouts.contains { calendar.isDate($0.startedAt, inSameDayAs: day) }
            let completed = sessions.contains { $0.status == .completed || $0.completedWorkout != nil }
            let openPlanned = sessions.contains { $0.status != .completed && $0.completedWorkout == nil }

            let state: WidgetSnapshot.DayMark.State
            if logged || completed { state = .done }
            else if openPlanned { state = .planned }
            else { state = .rest }

            return WidgetSnapshot.DayMark(letter: letter, state: state,
                                          isToday: calendar.isDate(day, inSameDayAs: today))
        }
    }
}
